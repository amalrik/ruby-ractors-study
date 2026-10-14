#!/usr/bin/env ruby
# frozen_string_literal: true

# Matriz completa do cenário CPU-bound (sequencial x threads x Ractors,
# vários workers e granularidades). Cada caso roda num subprocesso novo.
#
#   ruby cpu_bound/bin/bench.rb            # matriz padrão (~5–8 min)
#   ruby cpu_bound/bin/bench.rb --quick    # verificação rápida (~20 s)
#   ruby cpu_bound/bin/bench.rb --yjit     # mesma matriz com YJIT ligado
#   ruby cpu_bound/bin/bench.rb --modes ractors --env RUBY_MAX_CPU=16

require "etc"
require "optparse"
require_relative "../../common/lib/bench_common"
require_relative "../lib/primes"

ROOT = File.expand_path("..", __dir__)

opts = {
  limit: 2_000_000,
  blocks: [32, 512, 8192],
  workers: [1, 2, 4, 8, Etc.nprocessors].uniq.sort,
  modes: %w[sequential threads ractors],
  warmup: 1, reps: 5, prefetch: 1, yjit: false, env: {}
}
OptionParser.new do |o|
  o.on("--quick", "matriz reduzida para checar o ambiente") do
    opts.merge!(limit: 300_000, blocks: [64], workers: [1, 4], reps: 2)
  end
  o.on("--limit N", Integer) { |v| opts[:limit] = v }
  o.on("--blocks LIST", Array) { |v| opts[:blocks] = v.map(&:to_i) }
  o.on("--workers LIST", Array) { |v| opts[:workers] = v.map(&:to_i) }
  o.on("--modes LIST", Array) { |v| opts[:modes] = v }
  o.on("--reps N", Integer) { |v| opts[:reps] = v }
  o.on("--warmup N", Integer) { |v| opts[:warmup] = v }
  o.on("--prefetch N", Integer) { |v| opts[:prefetch] = v }
  o.on("--yjit") { opts[:yjit] = true }
  o.on("--env K=V", "variável de ambiente para os casos (ex.: RUBY_MAX_CPU=16)") do |v|
    k, val = v.split("=", 2)
    opts[:env][k] = val
  end
end.parse!

expected = Primes.sieve_count(opts[:limit])
$stderr.puts "Referência (crivo): #{expected} primos em [0, #{opts[:limit]})"

matrix = BenchCommon::Matrix.new(
  name: "CPU-bound: contagem de primos#{' (YJIT)' if opts[:yjit]}",
  case_script: File.join(ROOT, "bin/run_case.rb"),
  results_root: File.join(ROOT, "results"),
  case_keys: %i[blocks block_size mode workers],
  group_keys: %i[blocks],
  ruby_flags: opts[:yjit] ? ["--yjit"] : [],
  child_env: opts[:env]
)
matrix.write_environment(benchmark: "cpu_bound", options: opts, expected_primes: expected)

opts[:blocks].each do |blocks|
  $stderr.puts "\n# blocos=#{blocks} (tamanho ~#{(opts[:limit].to_f / blocks).ceil})"
  opts[:modes].each do |mode|
    worker_counts = mode == "sequential" ? [1] : opts[:workers]
    worker_counts.each do |w|
      matrix.run_case(%W[--mode #{mode} --workers #{w} --limit #{opts[:limit]} --blocks #{blocks}
                         --warmup #{opts[:warmup]} --reps #{opts[:reps]} --prefetch #{opts[:prefetch]}
                         --expected #{expected}])
    end
  end
end

matrix.finish
