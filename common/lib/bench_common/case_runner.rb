# frozen_string_literal: true

require "json"

module BenchCommon
  # Executa UM caso (modo + workers + carga) dentro de um processo novo:
  # 1 aquecimento + N repetições. Cada repetição cria e encerra o pool,
  # para medir inicialização separada do processamento.
  # Emite uma linha JSON por repetição no stdout.
  module CaseRunner
    module_function

    # validate: ->(run_result) { [valid_bool, "detalhe"] }
    def run(meta:, tasks:, handler:, ctx:, warmup:, reps:, validate:, prefetch: 1, io: $stdout)
      pool = Pools.for(meta.fetch(:mode), ractors: meta[:ractors])
      workers = meta.fetch(:workers)
      rows = []

      (warmup + reps).times do |i|
        is_warmup = i < warmup
        GC.start
        cpu0 = ProcMetrics.cpu_seconds
        sys0 = ProcMetrics.system_cpu_ticks
        r = pool.run(tasks, handler: handler, ctx: ctx, workers: workers, prefetch: prefetch)
        cpu = ProcMetrics.cpu_seconds - cpu0
        steal_pct = ProcMetrics.steal_pct_between(sys0, ProcMetrics.system_cpu_ticks)
        valid, detail = validate.call(r)

        timeouts = r.errors.count { |_, msg| msg =~ /timeout|timed out/i }
        row = meta.merge(
          rep: is_warmup ? "warmup" : i - warmup + 1,
          warmup: is_warmup,
          tasks: tasks.size,
          completed: r.results.size,
          errors: r.errors.size,
          timeouts: timeouts,
          valid: valid,
          validation: detail,
          startup_s: r.startup_s,
          process_s: r.process_s,
          shutdown_s: r.shutdown_s,
          total_s: r.total_s,
          throughput_per_s: r.results.size / r.process_s,
          task_p50_ms: ms(Stats.percentile(r.latencies, 50)),
          task_p95_ms: ms(Stats.percentile(r.latencies, 95)),
          task_p99_ms: ms(Stats.percentile(r.latencies, 99)),
          task_max_ms: ms(r.latencies.max),
          cpu_s: cpu,
          cpu_util: cpu / r.total_s,
          steal_pct: steal_pct,
          rss_kb_after: ProcMetrics.rss_kb,
          sample_errors: r.errors.first(3).map(&:last)
        )
        rows << row
        io.puts JSON.generate(row)
        io.flush
      end

      io.puts JSON.generate(meta.merge(kind: "process", peak_rss_kb: ProcMetrics.peak_rss_kb))
      rows
    end

    def ms(seconds) = seconds && seconds * 1000.0
  end
end
