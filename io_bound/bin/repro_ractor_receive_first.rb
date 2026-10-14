#!/usr/bin/env ruby
# frozen_string_literal: true

# Reprodução mínima do gatilho do limite de I/O em Ractors (Ruby 4.0, M:N).
# Sem pool e sem despachante: 64 Ractors, cada um com 6–7 operações TCP
# usando IO#wait_readable(5). A ÚNICA diferença entre os modos é se o
# Ractor fica bloqueado em Ractor.receive antes do primeiro I/O.
#
#   ruby io_bound/bin/repro_ractor_receive_first.rb direct         # rápido
#   ruby io_bound/bin/repro_ractor_receive_first.rb receive-first  # ~5x mais lento
#   ruby io_bound/bin/repro_ractor_receive_first.rb prime          # contorno parcial
#
# Cada modo deve rodar num processo novo: threads nativas criadas pelo
# runtime persistem e "contaminam" medições seguintes no mesmo processo.

require "rbconfig"
require "socket"

mode = ARGV.fetch(0, "direct")
abort "modos: direct, receive-first, prime" unless %w[direct receive-first prime].include?(mode)
workers = 64
ops = 400
delay_ms = 10

module TimedOp
  def self.call(id, port)
    s = TCPSocket.new("127.0.0.1", port)
    s.write("#{id}\n")
    s.wait_readable(5) or raise "timeout"
    s.gets == "ok #{id}\n" or raise "resposta inválida"
    s.close
  end
end

def native_threads = Dir.children("/proc/self/task").size

r, w = IO.pipe
server = Process.spawn(RbConfig.ruby, File.expand_path("delay_server.rb", __dir__), "--delay-ms", delay_ms.to_s,
                       out: w, err: File::NULL)
w.close
port = Integer(r.gets[/PORT (\d+)/, 1])

begin
  slices = (0...ops).each_slice(ops / workers).map(&:freeze)
  ractors = slices.map do |ids|
    Ractor.new(ids, port, mode) do |my_ids, p, m|
      (pr, _pw = IO.pipe; pr.wait_readable(0.001)) if m == "prime"
      Ractor.receive unless m == "direct"
      my_ids.each { |id| TimedOp.call(id, p) }
    end
  end
  sleep 0.05 unless mode == "direct" # todos bloqueados no receive
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ractors.each { |rc| rc << :go } unless mode == "direct"
  ractors.each(&:join)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  ideal = (ops.to_f / workers).ceil * (delay_ms + 0.5) / 1000
  puts format("Ruby %s RUBY_MAX_CPU=%s modo=%-13s %.3fs (ideal≈%.3fs) threads nativas=%d",
              RUBY_VERSION, ENV.fetch("RUBY_MAX_CPU", "padrão"), mode, elapsed, ideal, native_threads)
ensure
  Process.kill("TERM", server)
  Process.wait(server)
end
