#!/usr/bin/env ruby
# frozen_string_literal: true

# Executa UM caso de sessões e imprime uma linha JSON por repetição.
# Precisa de um session_server rodando.
#
#   ruby smtp_sessions/bin/run_case.rb --port 2525 --mode fibers --workers 1000 --sessions 3000

require "etc"
require "optparse"
require_relative "../../common/lib/bench_common"
require_relative "../lib/session_client"

opts = { mode: "fibers", workers: 100, sessions: nil, delay_ms: 10, body_bytes: 4096, host: "127.0.0.1",
         port: nil, timeout_s: 10.0, warmup: 1, reps: 3, ractors: nil, client_closes_first: false }
OptionParser.new do |o|
  o.on("--mode MODE", BenchCommon::Pools::MODES) { |v| opts[:mode] = v }
  o.on("--workers N", Integer, "sessões simultâneas") { |v| opts[:workers] = v }
  o.on("--sessions N", Integer, "sessões por repetição (padrão: 3 x workers, mín. 300)") { |v| opts[:sessions] = v }
  o.on("--delay-ms N", Integer, "atraso configurado no servidor (só registrado aqui)") { |v| opts[:delay_ms] = v }
  o.on("--body-bytes N", Integer, "tamanho do corpo enviado no DATA") { |v| opts[:body_bytes] = v }
  o.on("--host HOST") { |v| opts[:host] = v }
  o.on("--port N", Integer) { |v| opts[:port] = v }
  o.on("--timeout S", Float, "timeout de cada leitura/conexão") { |v| opts[:timeout_s] = v }
  o.on("--warmup N", Integer) { |v| opts[:warmup] = v }
  o.on("--reps N", Integer) { |v| opts[:reps] = v }
  o.on("--ractors N", Integer, "Ractors no modo ractor_fibers") { |v| opts[:ractors] = v }
  o.on("--client-closes-first", "cliente fecha antes do servidor (TIME_WAIT no cliente)") { opts[:client_closes_first] = true }
end.parse!
abort "--port é obrigatório" unless opts[:port]

sessions = opts[:sessions] || [opts[:workers] * 3, 300].max
tasks = Array.new(sessions) { |i| [i, i] }.freeze
body = SessionClient.build_body(opts[:body_bytes])
ctx = { host: opts[:host], port: opts[:port], timeout_s: opts[:timeout_s], body: body,
        client_closes_first: opts[:client_closes_first] }
expected_ids = (0...sessions).to_a

validate = lambda do |r|
  ids_ok = r.results.keys.sort == expected_ids
  [r.errors.empty? && ids_ok, "sessões=#{r.results.size}/#{sessions} erros=#{r.errors.size} ids_ok=#{ids_ok}"]
end

meta = {
  scenario: "smtp_like_sessions", workload: "session", mode: opts[:mode], workers: opts[:workers],
  ops: sessions, delay_ms: opts[:delay_ms], body_bytes: body.bytesize,
  ractors: opts[:mode] == "ractor_fibers" ? (opts[:ractors] || Etc.nprocessors) : nil
}

BenchCommon::CaseRunner.run(meta: meta, tasks: tasks, handler: SessionClient, ctx: ctx,
                            warmup: opts[:warmup], reps: opts[:reps], validate: validate)
