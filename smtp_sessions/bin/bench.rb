#!/usr/bin/env ruby
# frozen_string_literal: true

# Matriz do cenário de sessões parecidas com SMTP. Para cada caso sobe um
# session_server novo (prefork + async), roda o cliente num subprocesso
# novo e anexa as estatísticas do servidor (sessões, erros, CPU).
#
#   ruby smtp_sessions/bin/bench.rb              # 100..10000 sessões simultâneas
#   ruby smtp_sessions/bin/bench.rb --quick
#   ruby smtp_sessions/bin/bench.rb --workers 1000,20000 --modes fibers,ractor_fibers
#   ruby smtp_sessions/bin/bench.rb --host 10.0.0.2 --port 2525   # servidor externo

require "etc"
require "json"
require "optparse"
require "tmpdir"
require_relative "../../common/lib/bench_common"

ROOT = File.expand_path("..", __dir__)

opts = {
  workers: [100, 1000, 5000, 10_000], modes: %w[threads fibers ractor_fibers ractors],
  ractor_max_workers: 256, # Ractors puros: limitados a ~RUBY_MAX_CPU sessões (ver relatório)
  ractors: nil, delay_ms: 10, body_bytes: 4096, timeout_s: 10.0, server_procs: 4,
  warmup: 1, reps: 3, case_timeout: 600, host: nil, port: nil, env: {}
}
OptionParser.new do |o|
  o.on("--quick") { opts.merge!(workers: [100, 1000], reps: 1, modes: %w[threads fibers ractor_fibers]) }
  o.on("--workers LIST", Array, "sessões simultâneas") { |v| opts[:workers] = v.map(&:to_i) }
  o.on("--modes LIST", Array) { |v| opts[:modes] = v }
  o.on("--ractor-max-workers N", Integer, "maior concorrência testada no modo ractors puro") { |v| opts[:ractor_max_workers] = v }
  o.on("--ractors N", Integer, "Ractors no modo ractor_fibers (padrão: nproc)") { |v| opts[:ractors] = v }
  o.on("--delay-ms N", Integer) { |v| opts[:delay_ms] = v }
  o.on("--body-bytes N", Integer) { |v| opts[:body_bytes] = v }
  o.on("--timeout S", Float) { |v| opts[:timeout_s] = v }
  o.on("--server-procs N", Integer) { |v| opts[:server_procs] = v }
  o.on("--reps N", Integer) { |v| opts[:reps] = v }
  o.on("--warmup N", Integer) { |v| opts[:warmup] = v }
  o.on("--case-timeout S", Integer, "mata um caso travado após S segundos") { |v| opts[:case_timeout] = v }
  o.on("--host HOST", "usa servidor externo já rodando (não sobe um local)") { |v| opts[:host] = v }
  o.on("--port N", Integer) { |v| opts[:port] = v }
  o.on("--env K=V") { |v| k, val = v.split("=", 2); opts[:env][k] = val }
end.parse!

def start_server(opts, dir)
  stats = File.join(dir, "server-#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}.json")
  r, w = IO.pipe
  pid = Process.spawn(RbConfig.ruby, File.join(ROOT, "bin/session_server.rb"), "--procs", opts[:server_procs].to_s,
                      "--delay-ms", opts[:delay_ms].to_s, "--stats-file", stats, out: w, err: File::NULL)
  w.close
  line = r.gets or abort("session_server não iniciou")
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
  name: "Sessões parecidas com SMTP (delay #{opts[:delay_ms]} ms por resposta, corpo #{opts[:body_bytes]} B)",
  case_script: File.join(ROOT, "bin/run_case.rb"),
  results_root: File.join(ROOT, "results"),
  case_keys: %i[scenario mode ractors workers],
  group_keys: %i[scenario workers],
  child_env: opts[:env],
  case_timeout: opts[:case_timeout]
)
matrix.write_environment(benchmark: "smtp_sessions", options: opts)

Dir.mktmpdir("smtp-bench") do |tmp|
  opts[:workers].each do |w|
    $stderr.puts "\n# sessões simultâneas=#{w}"
    opts[:modes].each do |mode|
      next if mode == "ractors" && w > opts[:ractor_max_workers]

      argv = %W[--mode #{mode} --workers #{w} --delay-ms #{opts[:delay_ms]} --body-bytes #{opts[:body_bytes]}
                --timeout #{opts[:timeout_s]} --warmup #{opts[:warmup]} --reps #{opts[:reps]}]
      argv += %W[--ractors #{opts[:ractors]}] if opts[:ractors] && mode == "ractor_fibers"
      if opts[:host]
        matrix.run_case(argv + %W[--host #{opts[:host]} --port #{opts[:port]}])
      else
        pid, port, stats_file = start_server(opts, tmp)
        matrix.run_case(argv + %W[--port #{port}]) do
          s = stop_server(pid, stats_file)
          { server_max_concurrent: s[:max_concurrent], server_accepted: s[:sessions], server_errors: s[:errors],
            server_procs: s[:procs], server_cpu_s: s[:cpu_s] }
        end
      end
    end
  end
end

matrix.finish
