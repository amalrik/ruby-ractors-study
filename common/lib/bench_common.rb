# frozen_string_literal: true

# Biblioteca compartilhada pelos projetos cpu_bound/ e io_bound/.
# Única dependência externa: gem `async` (modos com Fibers); ver Gemfile.

# Usa o Gemfile da raiz (gem `async` para os modos de Fibers) quando disponível.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../Gemfile", __dir__)
begin
  require "bundler/setup"
rescue LoadError, StandardError => e
  warn "bench_common: bundler indisponível (#{e.class}); modos com Fibers podem falhar"
end

module BenchCommon
  module Clock
    def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

require_relative "bench_common/stats"
require_relative "bench_common/proc_metrics"
require_relative "bench_common/environment"
require_relative "bench_common/pools"
require_relative "bench_common/case_runner"
require_relative "bench_common/matrix"
