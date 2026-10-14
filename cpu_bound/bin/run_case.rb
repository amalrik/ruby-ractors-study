#!/usr/bin/env ruby
# frozen_string_literal: true

# Executa UM caso CPU-bound e imprime uma linha JSON por repetição.
#
#   ruby cpu_bound/bin/run_case.rb --mode ractors --workers 8 --limit 2000000 --blocks 512
#
# Use --expected para validar contra uma contagem conhecida; sem ele,
# a referência é calculada aqui por crivo de Eratóstenes.

require "optparse"
require_relative "../../common/lib/bench_common"
require_relative "../lib/primes"

opts = { mode: "sequential", workers: 1, limit: 2_000_000, blocks: 512, warmup: 1, reps: 5,
         prefetch: 1, expected: nil }
OptionParser.new do |o|
  o.on("--mode MODE", BenchCommon::Pools::MODES) { |v| opts[:mode] = v }
  o.on("--workers N", Integer) { |v| opts[:workers] = v }
  o.on("--limit N", Integer, "intervalo [0, N)") { |v| opts[:limit] = v }
  o.on("--blocks N", Integer, "quantidade de blocos") { |v| opts[:blocks] = v }
  o.on("--warmup N", Integer) { |v| opts[:warmup] = v }
  o.on("--reps N", Integer) { |v| opts[:reps] = v }
  o.on("--prefetch N", Integer, "tarefas em voo por Ractor") { |v| opts[:prefetch] = v }
  o.on("--expected N", Integer, "contagem esperada de primos") { |v| opts[:expected] = v }
end.parse!

tasks = Primes.blocks(opts[:limit], opts[:blocks])
expected = opts[:expected] || Primes.sieve_count(opts[:limit])
expected_ids = tasks.map(&:first).sort

validate = lambda do |r|
  total = r.results.values.sum
  ids_ok = r.results.keys.sort == expected_ids
  ok = r.errors.empty? && ids_ok && total == expected
  [ok, "primos=#{total} esperado=#{expected} blocos_ok=#{ids_ok}"]
end

meta = {
  scenario: "cpu_primes", workload: "trial_division", mode: opts[:mode], workers: opts[:workers],
  limit: opts[:limit], blocks: tasks.size, block_size: (opts[:limit].to_f / opts[:blocks]).ceil,
  prefetch: opts[:mode] == "ractors" ? opts[:prefetch] : nil
}

BenchCommon::CaseRunner.run(meta: meta, tasks: tasks, handler: Primes::Handler, ctx: {},
                            warmup: opts[:warmup], reps: opts[:reps], validate: validate,
                            prefetch: opts[:prefetch])
