#!/usr/bin/env ruby
# frozen_string_literal: true

# Reprodutor do travamento intermitente de clientes de sessão em Ractors
# (Ruby 4.0.6). UMA tentativa por processo: 8 Ractors workers (pool com
# Ractor::Port) executam sessões de várias etapas contra um servidor de
# THREADS (sem async). Sai com 0 quando termina; quando trava, o processo
# fica parado e o script de controle o mata.
#
#   ruby smtp_sessions/bin/repro_ractor_session_hang.rb <opções> [sessões] [pools]
#
#   <opções> é uma lista separada por vírgulas (ou "none") de:
#     ct     TCPSocket.new(..., connect_timeout: 10)
#     iot    sock.timeout = 10 (IO#timeout) antes das leituras
#     wr     wait_readable(10) antes de cada gets
#     body4k corpo do DATA com ~4 KB em um único write (senão ~300 B)
#     float  timeouts em Float (10.0) em vez de Integer (10)
#   "real" usa o SessionClient do benchmark (equivale a ct,iot,body4k).
#   [pools] quantas vezes o pool é executado no mesmo processo (padrão 1).
#
# Laço de controle sugerido (conta travamentos em 10 tentativas):
#   for i in $(seq 10); do timeout -s KILL 30 ruby smtp_sessions/bin/repro_ractor_session_hang.rb ct,iot,body4k; echo $?; done

require "rbconfig"
require_relative "../../common/lib/bench_common"
require "socket"
require_relative "../lib/session_client"

variant = ARGV.fetch(0)
sessions = Integer(ARGV[1] || 300)
pools = Integer(ARGV[2] || 1)

module Session
  def self.call(id, ctx)
    opts = ctx[:opts]
    sock = opts.include?("ct") ? TCPSocket.new("127.0.0.1", ctx[:port], connect_timeout: ctx[:t]) : TCPSocket.new("127.0.0.1", ctx[:port])
    sock.timeout = ctx[:t] if opts.include?("iot")
    begin
      read_line(sock, opts)
      %W[EHLO\sc#{id} MAIL\sFROM:<a@b> RCPT\sTO:<c@d> DATA].each do |cmd|
        sock.write("#{cmd}\r\n")
        read_line(sock, opts)
      end
      sock.write(ctx[:body])
      sock.write(".\r\n")
      read_line(sock, opts)
      sock.write("QUIT\r\n")
      read_line(sock, opts)
      id
    ensure
      sock.close
    end
  end

  def self.read_line(sock, opts)
    raise "timeout" if opts.include?("wr") && !sock.wait_readable(10.0)

    sock.gets or raise "conexão fechada"
  end
end

server_script = File.expand_path("session_server.rb", __dir__)
r, w = IO.pipe
server = Process.spawn(RbConfig.ruby, server_script, "--procs", "4", "--delay-ms", "10", "--engine", "prefork_threads",
                       out: w, err: File::NULL)
w.close
port = Integer(r.gets[/PORT (\d+)/, 1])

begin
  tasks = Array.new(sessions) { |i| [i, i] }.freeze
  handler, ctx =
    if variant == "real"
      [SessionClient, { host: "127.0.0.1", port: port, timeout_s: 10.0, body: SessionClient.build_body(4096) }]
    else
      opts = variant == "none" ? [] : variant.split(",")
      [Session, { port: port, opts: opts, t: opts.include?("float") ? 10.0 : 10,
                  body: SessionClient.build_body(opts.include?("body4k") ? 4096 : 300) }]
    end
  pools.times do |n|
    res = BenchCommon::Pools::RactorPool.new.run(tasks, handler: handler, ctx: ctx, workers: 8)
    puts format("variante=%s pool=%d sessões=%d erros=%d tempo=%.2fs", variant, n + 1, res.results.size,
                res.errors.size, res.process_s)
    $stdout.flush
  end
ensure
  Process.kill("TERM", server)
  Process.wait(server)
end
