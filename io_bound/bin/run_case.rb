#!/usr/bin/env ruby
# frozen_string_literal: true

# Executa UM caso I/O-bound e imprime uma linha JSON por repetição.
#
#   # com rede (precisa de um delay_server rodando):
#   ruby io_bound/bin/run_case.rb --workload tcp --port 9500 --mode threads --workers 32
#   # simulação de espera (sem rede):
#   ruby io_bound/bin/run_case.rb --workload sleep --mode ractors --workers 32

require "etc"
require "optparse"
require_relative "../../common/lib/bench_common"
require_relative "../lib/io_ops"

opts = { workload: "tcp", mode: "sequential", workers: 1, ops: 1000, delay_ms: 10, host: "127.0.0.1",
         port: nil, timeout_s: 5.0, warmup: 1, reps: 5, prefetch: 1, ractors: nil }
OptionParser.new do |o|
  o.on("--workload KIND", IoOps::HANDLERS.keys) { |v| opts[:workload] = v }
  o.on("--mode MODE", BenchCommon::Pools::MODES) { |v| opts[:mode] = v }
  o.on("--workers N", Integer, "nível de concorrência") { |v| opts[:workers] = v }
  o.on("--ops N", Integer, "total de operações por repetição") { |v| opts[:ops] = v }
  o.on("--delay-ms N", Integer, "atraso (sleep) ou atraso configurado no servidor (tcp)") { |v| opts[:delay_ms] = v }
  o.on("--host HOST") { |v| opts[:host] = v }
  o.on("--port N", Integer) { |v| opts[:port] = v }
  o.on("--timeout S", Float) { |v| opts[:timeout_s] = v }
  o.on("--warmup N", Integer) { |v| opts[:warmup] = v }
  o.on("--reps N", Integer) { |v| opts[:reps] = v }
  o.on("--prefetch N", Integer) { |v| opts[:prefetch] = v }
  o.on("--ractors N", Integer, "Ractors no modo ractor_fibers") { |v| opts[:ractors] = v }
end.parse!
abort "--port é obrigatório para --workload tcp" if opts[:workload] == "tcp" && opts[:port].nil?

tasks = Array.new(opts[:ops]) { |i| [i, i] }.freeze
ctx = { host: opts[:host], port: opts[:port], timeout_s: opts[:timeout_s], delay_s: opts[:delay_ms] / 1000.0 }
expected_ids = (0...opts[:ops]).to_a

validate = lambda do |r|
  ids_ok = r.results.keys.sort == expected_ids && r.results.all? { |k, v| k == v }
  [r.errors.empty? && ids_ok, "concluídas=#{r.results.size}/#{opts[:ops]} erros=#{r.errors.size} ids_ok=#{ids_ok}"]
end

meta = {
  scenario: opts[:workload] == "tcp" ? "io_tcp" : "io_sleep_simulation",
  workload: opts[:workload], mode: opts[:mode], workers: opts[:workers], ops: opts[:ops],
  delay_ms: opts[:delay_ms], prefetch: opts[:mode] == "ractors" ? opts[:prefetch] : nil,
  ractors: opts[:mode] == "ractor_fibers" ? (opts[:ractors] || Etc.nprocessors) : nil
}

BenchCommon::CaseRunner.run(meta: meta, tasks: tasks, handler: IoOps::HANDLERS.fetch(opts[:workload]), ctx: ctx,
                            warmup: opts[:warmup], reps: opts[:reps], validate: validate,
                            prefetch: opts[:prefetch])
