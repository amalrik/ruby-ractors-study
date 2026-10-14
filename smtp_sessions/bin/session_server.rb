#!/usr/bin/env ruby
# frozen_string_literal: true

# Sobe o servidor de sessões com o motor escolhido. Imprime "PORT <n>"
# quando está aceitando conexões. No TERM/INT encerra, agrega as
# estatísticas e grava em --stats-file (JSON): sessões, erros, CPU e RSS de
# pico do(s) processo(s) do servidor, steal da máquina durante a execução
# e um resumo do ambiente.
#
#   ruby smtp_sessions/bin/session_server.rb --engine fibers --port 2525
#   ruby smtp_sessions/bin/session_server.rb --engine ractor_fibers --workers 8 --host 0.0.0.0 --port 2525

require "json"
require "optparse"
require_relative "../../common/lib/bench_common"
require_relative "../lib/session_server"

opts = { host: "127.0.0.1", port: 0, delay_ms: 10, workers: 4, engine: "prefork_fibers", stats_file: nil }
OptionParser.new do |o|
  o.on("--engine NAME", SessionServer::ENGINES + SessionServer::ALIASES.keys,
       "modelo de concorrência (#{SessionServer::ENGINES.join(', ')})") { |v| opts[:engine] = v }
  o.on("--workers N", "--procs N", Integer, "processos (prefork_*) ou Ractors (ractor_fibers)") { |v| opts[:workers] = v }
  o.on("--host HOST", "endereço de escuta (0.0.0.0 para aceitar de fora)") { |v| opts[:host] = v }
  o.on("--port N", Integer) { |v| opts[:port] = v }
  o.on("--delay-ms N", Integer, "atraso antes de cada resposta") { |v| opts[:delay_ms] = v }
  o.on("--stats-file PATH") { |v| opts[:stats_file] = v }
end.parse!

runner = SessionServer::Runner.new(engine: opts[:engine], host: opts[:host], port: opts[:port],
                                   delay_ms: opts[:delay_ms], workers: opts[:workers]).start
sys0 = BenchCommon::ProcMetrics.system_cpu_ticks
t0 = BenchCommon::Clock.now

wake_r, wake_w = IO.pipe
%w[TERM INT].each { |sig| trap(sig) { wake_w.write_nonblock(".") rescue nil } }
$stdout.puts "PORT #{runner.port}"
$stdout.flush

wake_r.read(1)
stats = runner.stop
env = BenchCommon::Environment.capture
total = stats.merge(
  procs: stats[:workers], # nome antigo, usado pelos orquestradores
  delay_ms: opts[:delay_ms],
  uptime_s: BenchCommon::Clock.now - t0,
  steal_pct: BenchCommon::ProcMetrics.steal_pct_between(sys0, BenchCommon::ProcMetrics.system_cpu_ticks),
  host_env: env.slice(:os, :kernel, :cpu_model, :logical_cpus, :physical_cores, :mem_total_kb,
                      :virtualization, :ruby_description, :somaxconn, :tcp_max_syn_backlog, :nofile_limit)
)
File.write(opts[:stats_file], JSON.generate(total)) if opts[:stats_file]
$stderr.puts "session_server: #{total.except(:error_samples, :host_env, :per_worker_sessions)}"
