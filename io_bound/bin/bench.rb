#!/usr/bin/env ruby
# frozen_string_literal: true

# Matriz completa do cenário I/O-bound. Para cada caso TCP sobe um
# DelayServer novo (processo separado), roda o caso num subprocesso
# cliente novo, encerra o servidor e anexa as estatísticas dele.
#
#   ruby io_bound/bin/bench.rb                    # tcp + simulação sleep (~5 min)
#   ruby io_bound/bin/bench.rb --quick            # verificação rápida
#   ruby io_bound/bin/bench.rb --workloads tcp    # só rede
#   ruby io_bound/bin/bench.rb --workloads tcp --modes ractors --env RUBY_MAX_CPU=256

require "json"
require "optparse"
require "tmpdir"
require_relative "../../common/lib/bench_common"

ROOT = File.expand_path("..", __dir__)

opts = {
  workloads: %w[tcp sleep], ops: 2000, delay_ms: 10, workers: [8, 32, 128, 256],
  modes: BenchCommon::Pools::MODES, warmup: 1, reps: 5, seq_reps: 3, prefetch: 1, ractors: nil, yjit: false, env: {}
}
OptionParser.new do |o|
  o.on("--quick") { opts.merge!(ops: 200, workers: [8, 64], reps: 2, seq_reps: 1) }
  o.on("--workloads LIST", Array) { |v| opts[:workloads] = v }
  o.on("--ops N", Integer) { |v| opts[:ops] = v }
  o.on("--delay-ms N", Integer) { |v| opts[:delay_ms] = v }
  o.on("--workers LIST", Array) { |v| opts[:workers] = v.map(&:to_i) }
  o.on("--modes LIST", Array) { |v| opts[:modes] = v }
  o.on("--reps N", Integer) { |v| opts[:reps] = v }
  o.on("--seq-reps N", Integer, "repetições do modo sequencial (é o mais lento)") { |v| opts[:seq_reps] = v }
  o.on("--warmup N", Integer) { |v| opts[:warmup] = v }
  o.on("--prefetch N", Integer) { |v| opts[:prefetch] = v }
  o.on("--ractors N", Integer, "Ractors no modo ractor_fibers (padrão: nproc)") { |v| opts[:ractors] = v }
  o.on("--yjit") { opts[:yjit] = true }
  o.on("--env K=V", "variável de ambiente para os clientes (ex.: RUBY_MAX_CPU=256)") do |v|
    k, val = v.split("=", 2)
    opts[:env][k] = val
  end
end.parse!

# Sobe o servidor, devolve [pid, port, stats_file].
def start_server(delay_ms, dir)
  stats = File.join(dir, "server-#{Process.clock_gettime(Process::CLOCK_MONOTONIC_RAW, :nanosecond)}.json")
  r, w = IO.pipe
  pid = Process.spawn(RbConfig.ruby, File.join(ROOT, "bin/delay_server.rb"), "--delay-ms", delay_ms.to_s,
                      "--stats-file", stats, out: w)
  w.close
  line = r.gets or abort("delay_server não iniciou")
  r.close
  [pid, Integer(line[/PORT (\d+)/, 1]), stats]
end

def stop_server(pid, stats_file)
  Process.kill("TERM", pid)
  Process.wait(pid)
  JSON.parse(File.read(stats_file), symbolize_names: true)
rescue StandardError => e
  { errors: -1, error_samples: ["stats indisponíveis: #{e.message}"] }
end

matrix = BenchCommon::Matrix.new(
  name: "I/O-bound#{' (YJIT)' if opts[:yjit]}",
  case_script: File.join(ROOT, "bin/run_case.rb"),
  results_root: File.join(ROOT, "results"),
  case_keys: %i[scenario delay_ms ops mode ractors workers],
  group_keys: %i[scenario],
  ruby_flags: opts[:yjit] ? ["--yjit"] : [],
  child_env: opts[:env]
)
matrix.write_environment(benchmark: "io_bound", options: opts)

Dir.mktmpdir("io-bench") do |tmp|
  opts[:workloads].each do |workload|
    $stderr.puts "\n# workload=#{workload} ops=#{opts[:ops]} delay=#{opts[:delay_ms]}ms" \
                 "#{' (SIMULAÇÃO: sleep, sem rede)' if workload == 'sleep'}"
    opts[:modes].each do |mode|
      (mode == "sequential" ? [1] : opts[:workers]).each do |w|
        reps = mode == "sequential" ? opts[:seq_reps] : opts[:reps]
        argv = %W[--workload #{workload} --mode #{mode} --workers #{w} --ops #{opts[:ops]}
                  --delay-ms #{opts[:delay_ms]} --warmup #{opts[:warmup]} --reps #{reps}
                  --prefetch #{opts[:prefetch]}]
        argv += %W[--ractors #{opts[:ractors]}] if opts[:ractors]
        if workload == "tcp"
          pid, port, stats_file = start_server(opts[:delay_ms], tmp)
          matrix.run_case(argv + %W[--port #{port}]) do
            s = stop_server(pid, stats_file)
            { server_max_concurrent: s[:max_concurrent], server_accepted: s[:accepted], server_errors: s[:errors] }
          end
        else
          matrix.run_case(argv)
        end
      end
    end
  end
end

matrix.finish
