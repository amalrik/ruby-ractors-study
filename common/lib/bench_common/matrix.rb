# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "open3"
require "rbconfig"

module BenchCommon
  # Orquestra uma matriz de casos: cada caso roda num subprocesso Ruby
  # novo (isola GC, RSS de pico e estado de Ractors), coleta as linhas
  # JSON emitidas por CaseRunner e grava resultados brutos + resumo.
  class Matrix
    RAW_FIELDS = %i[
      scenario workload mode workers ractors blocks block_size limit ops delay_ms concurrency prefetch yjit
      child_env rep warmup tasks completed errors timeouts valid validation
      startup_s process_s shutdown_s total_s throughput_per_s
      task_p50_ms task_p95_ms task_p99_ms task_max_ms cpu_s cpu_util steal_pct rss_kb_after peak_rss_kb
      server_engine server_workers server_max_concurrent server_accepted server_errors server_procs server_cpu_s
      server_peak_rss_kb server_steal_pct server_per_worker rtt_ms client_mode body_bytes sample_errors
    ].freeze

    attr_reader :out_dir, :rows

    def initialize(name:, case_script:, results_root:, case_keys:, group_keys:, ruby_flags: [], child_env: {},
                   case_timeout: 900)
      @name = name
      @case_script = case_script
      @case_keys = case_keys
      @group_keys = group_keys
      @ruby_flags = ruby_flags
      @child_env = child_env
      @case_timeout = case_timeout
      @rows = []
      @failures = []
      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      @out_dir = File.join(results_root, stamp)
      FileUtils.mkdir_p(@out_dir)
      @raw_jsonl = File.open(File.join(@out_dir, "raw.jsonl"), "w")
      @started = Clock.now
    end

    def write_environment(extra = {})
      env = Environment.capture(extra.merge(ruby_flags: @ruby_flags, child_env: @child_env, command: [$PROGRAM_NAME, *ARGV].join(" ")))
      File.write(File.join(@out_dir, "environment.json"), JSON.pretty_generate(env))
      env
    end

    # Roda um caso; extra_meta é mesclado a todas as linhas (ex.: stats do servidor).
    def run_case(argv, extra_meta = {})
      cmd = [RbConfig.ruby, *@ruby_flags, @case_script, *argv]
      label = argv.join(" ")
      $stderr.print "  -> #{label} ... "
      t0 = Clock.now
      stdout, stderr, status, timed_out = capture_with_timeout(cmd)
      lines = stdout.lines.filter_map { |l| JSON.parse(l, symbolize_names: true) if l.start_with?("{") }
      peak = lines.find { |l| l[:kind] == "process" }&.dig(:peak_rss_kb)
      rows = lines.reject { |l| l[:kind] == "process" }.map do |l|
        l.merge(peak_rss_kb: peak, yjit: @ruby_flags.include?("--yjit"),
                child_env: @child_env.map { |k, v| "#{k}=#{v}" }.join(" "))
      end

      unless status.success?
        reason = timed_out ? "timeout de #{@case_timeout}s (processo morto com KILL; possível travamento)" : "exit #{status.exitstatus}"
        @failures << { argv: argv, exit: status.exitstatus, reason: reason, completed_rows: rows.size,
                       stderr: stderr.lines.last(10).join }
        $stderr.puts "FALHOU (#{reason})"
        $stderr.puts stderr.lines.last(10).join.gsub(/^/, "     ")
      end
      # O bloco pode devolver metadados obtidos só após o caso (ex.: stats do servidor).
      extra_meta = extra_meta.merge(yield(rows) || {}) if block_given?
      rows = rows.map { |r| r.merge(extra_meta) }
      rows.each { |r| @raw_jsonl.puts(JSON.generate(r)) }
      @raw_jsonl.flush
      @rows.concat(rows)
      if status.success?
        meas = rows.reject { |r| r[:warmup] }
        med = Stats.median(meas.map { |r| r[:total_s] })
        $stderr.puts format("ok (%.1fs, mediana total %.3fs, válido=%s)", Clock.now - t0, med || 0,
                            meas.all? { |r| r[:valid] })
      end
      rows
    end

    def finish
      @raw_jsonl.close
      write_raw_csv
      summary = build_summary
      write_summary_csv(summary)
      md = summary_markdown(summary)
      File.write(File.join(@out_dir, "summary.md"), md)
      File.write(File.join(@out_dir, "failures.json"), JSON.pretty_generate(@failures)) unless @failures.empty?
      results_root = File.dirname(@out_dir)
      File.write(File.join(results_root, "LATEST"), File.basename(@out_dir) + "\n")
      puts md
      $stderr.puts format("\nTempo total da matriz: %.1fs. Resultados em %s", Clock.now - @started, @out_dir)
      summary
    end

    private

    # Como Open3.capture3, mas mata o caso (KILL) se passar de @case_timeout.
    # Linhas já emitidas (repetições concluídas) são preservadas.
    def capture_with_timeout(cmd)
      Open3.popen3(@child_env, *cmd) do |stdin, out, err, waiter|
        stdin.close
        out_reader = Thread.new { out.read }
        err_reader = Thread.new { err.read }
        timed_out = waiter.join(@case_timeout).nil?
        begin
          Process.kill("KILL", waiter.pid) if timed_out
        rescue Errno::ESRCH
          nil # terminou entre o join e o kill
        end
        [out_reader.value, err_reader.value, waiter.value, timed_out]
      end
    end

    def write_raw_csv
      CSV.open(File.join(@out_dir, "raw.csv"), "w") do |csv|
        csv << RAW_FIELDS
        @rows.each { |r| csv << RAW_FIELDS.map { |f| fmt_cell(r[f]) } }
      end
    end

    def fmt_cell(v)
      case v
      when Float then v.round(6)
      when Array then v.join(" | ")
      else v
      end
    end

    def build_summary
      measured = @rows.reject { |r| r[:warmup] }
      groups = measured.group_by { |r| @case_keys.map { |k| r[k] } }
      summary = groups.map do |_key, rs|
        first = rs.first
        total = Stats.summarize(rs.map { |r| r[:total_s] })
        process = Stats.summarize(rs.map { |r| r[:process_s] })
        startup = Stats.summarize(rs.map { |r| r[:startup_s] })
        shutdown = Stats.summarize(rs.map { |r| r[:shutdown_s] })
        @case_keys.to_h { |k| [k, first[k]] }.merge(
          reps: rs.size,
          all_valid: rs.all? { |r| r[:valid] },
          errors: rs.sum { |r| r[:errors].to_i },
          timeouts: rs.sum { |r| r[:timeouts].to_i },
          completed_median: Stats.median(rs.map { |r| r[:completed] }),
          tasks: first[:tasks],
          total_median_s: total[:median], total_min_s: total[:min], total_max_s: total[:max],
          process_median_s: process[:median], process_min_s: process[:min], process_max_s: process[:max],
          startup_median_ms: startup[:median] && startup[:median] * 1000,
          startup_max_ms: startup[:max] && startup[:max] * 1000,
          shutdown_median_ms: shutdown[:median] && shutdown[:median] * 1000,
          throughput_median: Stats.median(rs.map { |r| r[:throughput_per_s] }),
          task_p50_ms: Stats.median(rs.map { |r| r[:task_p50_ms] }.compact),
          task_p95_ms: Stats.median(rs.map { |r| r[:task_p95_ms] }.compact),
          task_p99_ms: Stats.median(rs.map { |r| r[:task_p99_ms] }.compact),
          cpu_util_median: Stats.median(rs.map { |r| r[:cpu_util] }),
          steal_pct_max: rs.map { |r| r[:steal_pct] }.compact.max,
          peak_rss_mb: first[:peak_rss_kb] && first[:peak_rss_kb] / 1024.0,
          server_max_concurrent: rs.map { |r| r[:server_max_concurrent] }.compact.max,
          server_cpu_s: first[:server_cpu_s],
          server_peak_rss_mb: first[:server_peak_rss_kb] && first[:server_peak_rss_kb] / 1024.0,
          server_steal_pct: first[:server_steal_pct],
          rtt_ms: first[:rtt_ms]
        )
      end

      # Speedup vs. sequencial dentro do mesmo grupo (ex.: mesmo tamanho de bloco).
      summary.group_by { |s| @group_keys.map { |k| s[k] } }.each_value do |ss|
        base = ss.find { |s| s[:mode] == "sequential" }
        ss.each do |s|
          s[:speedup_vs_seq] = base && s[:total_median_s] ? base[:total_median_s] / s[:total_median_s] : nil
        end
      end
      summary
    end

    def write_summary_csv(summary)
      return if summary.empty?

      CSV.open(File.join(@out_dir, "summary.csv"), "w") do |csv|
        csv << summary.first.keys
        summary.each { |s| csv << s.values.map { |v| fmt_cell(v) } }
      end
    end

    def summary_markdown(summary)
      cols = [*@case_keys,
              ["válido", ->(s) { s[:all_valid] ? "sim" : "**NÃO**" }],
              ["erros/timeouts", ->(s) { "#{s[:errors]}/#{s[:timeouts]}" }],
              ["total mediana s (mín–máx)", ->(s) { range(s[:total_median_s], s[:total_min_s], s[:total_max_s]) }],
              ["startup ms", ->(s) { f(s[:startup_median_ms], 1) }],
              ["process mediana s", ->(s) { f(s[:process_median_s], 3) }],
              ["vazão/s", ->(s) { f(s[:throughput_median], 1) }],
              ["tarefa p50/p95/p99 ms", ->(s) { "#{f(s[:task_p50_ms], 2)} / #{f(s[:task_p95_ms], 2)} / #{f(s[:task_p99_ms], 2)}" }],
              ["CPU util", ->(s) { f(s[:cpu_util_median], 2) }],
              ["RSS pico MB", ->(s) { f(s[:peak_rss_mb], 1) }],
              ["speedup", ->(s) { s[:speedup_vs_seq] ? "#{f(s[:speedup_vs_seq], 2)}x" : "-" }]]
      cols << ["srv conc. máx", ->(s) { s[:server_max_concurrent] || "-" }] if summary.any? { |s| s[:server_max_concurrent] }
    cols << ["srv CPU s (caso)", ->(s) { f(s[:server_cpu_s], 1) }] if summary.any? { |s| s[:server_cpu_s] }
    cols << ["srv RSS pico MB", ->(s) { f(s[:server_peak_rss_mb], 1) }] if summary.any? { |s| s[:server_peak_rss_mb] }
    cols << ["srv steal %", ->(s) { f(s[:server_steal_pct], 1) }] if summary.any? { |s| s[:server_steal_pct].to_f >= 0.5 }
    cols << ["RTT ms", ->(s) { f(s[:rtt_ms], 2) }] if summary.any? { |s| s[:rtt_ms] }
    # Steal só aparece quando houve (típico de VPS); sempre fica no CSV.
    cols << ["steal máx %", ->(s) { f(s[:steal_pct_max], 1) }] if summary.any? { |s| s[:steal_pct_max].to_f >= 0.5 }

      header = cols.map { |c| c.is_a?(Array) ? c[0] : c.to_s }
      env_note = @child_env.empty? ? "" : " (env: #{@child_env.map { |k, v| "#{k}=#{v}" }.join(' ')})"
      lines = ["## #{@name}#{env_note} — #{File.basename(@out_dir)}", "",
               "| #{header.join(' | ')} |", "|#{header.map { '---' }.join('|')}|"]
      summary.each do |s|
        lines << "| #{cols.map { |c| c.is_a?(Array) ? c[1].call(s) : s[c] }.join(' | ')} |"
      end
      unless @failures.empty?
        lines << "" << "Casos com falha: #{@failures.map { |x| x[:argv].join(' ') }.join('; ')}"
      end
      lines.join("\n") + "\n"
    end

    def f(v, d) = v.nil? ? "n/m" : format("%.#{d}f", v)
    def range(m, lo, hi) = m.nil? ? "n/m" : format("%.3f (%.3f–%.3f)", m, lo, hi)
  end
end
