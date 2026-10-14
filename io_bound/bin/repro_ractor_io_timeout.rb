#!/usr/bin/env ruby
# frozen_string_literal: true

# Reprodução isolada do achado: dentro de Ractors workers (pool de longa
# duração), uma espera de socket COM timeout (IO#wait_readable(t) ou
# IO#timeout=) não escala além de ~RUBY_MAX_CPU workers simultâneos,
# enquanto a mesma operação SEM timeout, `sleep` e threads escalam.
#
#   ruby io_bound/bin/repro_ractor_io_timeout.rb [workers] [ops]
#   RUBY_MAX_CPU=64 ruby io_bound/bin/repro_ractor_io_timeout.rb
#
# Ideal com atraso de 10 ms: ceil(ops / workers) * ~10.5 ms.

require "json"
require "rbconfig"
require_relative "../../common/lib/bench_common"
require "socket"

workers = Integer(ARGV[0] || 64)
ops = Integer(ARGV[1] || 400)
delay_ms = 10

module NoTimeout
  def self.call(id, c)
    s = TCPSocket.new(c[:host], c[:port])
    s.write("#{id}\n")
    s.gets == "ok #{id}\n" or raise "resposta inválida"
    s.close
    id
  end
end

module WaitReadableTimeout
  def self.call(id, c)
    s = TCPSocket.new(c[:host], c[:port])
    s.write("#{id}\n")
    s.wait_readable(5) or raise "timeout"
    s.gets == "ok #{id}\n" or raise "resposta inválida"
    s.close
    id
  end
end

module IoTimeoutAttr
  def self.call(id, c)
    s = TCPSocket.new(c[:host], c[:port])
    s.timeout = 5
    s.write("#{id}\n")
    s.gets == "ok #{id}\n" or raise "resposta inválida"
    s.close
    id
  end
end

module ConnectTimeoutOnly
  def self.call(id, c)
    s = TCPSocket.new(c[:host], c[:port], connect_timeout: 5)
    s.write("#{id}\n")
    s.gets == "ok #{id}\n" or raise "resposta inválida"
    s.close
    id
  end
end

server_script = File.expand_path("delay_server.rb", __dir__)
r, w = IO.pipe
pid = Process.spawn(RbConfig.ruby, server_script, "--delay-ms", delay_ms.to_s, out: w, err: File::NULL)
w.close
port = Integer(r.gets[/PORT (\d+)/, 1])

ctx = { host: "127.0.0.1", port: port }
tasks = Array.new(ops) { |i| [i, i] }.freeze
ideal = (ops.to_f / workers).ceil * (delay_ms + 0.5) / 1000.0

puts "Ruby #{RUBY_VERSION}  workers=#{workers} ops=#{ops} delay=#{delay_ms}ms  " \
     "RUBY_MAX_CPU=#{ENV.fetch('RUBY_MAX_CPU', '(padrão)')}  ideal≈#{format('%.3f', ideal)}s"
begin
  [["sem timeout", NoTimeout], ["connect_timeout:", ConnectTimeoutOnly],
   ["wait_readable(5)", WaitReadableTimeout], ["IO#timeout = 5", IoTimeoutAttr]].each do |name, handler|
    rr = BenchCommon::Pools::RactorPool.new.run(tasks, handler: handler, ctx: ctx, workers: workers)
    tr = BenchCommon::Pools::ThreadPool.new.run(tasks, handler: handler, ctx: ctx, workers: workers)
    puts format("  %-18s ractors %.3fs (erros %d) | threads %.3fs (erros %d)",
                name, rr.process_s, rr.errors.size, tr.process_s, tr.errors.size)
  end
ensure
  Process.kill("TERM", pid)
  Process.wait(pid)
end
