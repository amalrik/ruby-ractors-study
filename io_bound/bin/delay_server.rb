#!/usr/bin/env ruby
# frozen_string_literal: true

# Sobe o servidor de atraso. Imprime "PORT <n>" no stdout quando pronto.
# Ao receber TERM/INT grava estatísticas em --stats-file (JSON) e sai.
#
#   ruby io_bound/bin/delay_server.rb --delay-ms 10 --port 9500

require "optparse"
require_relative "../lib/delay_server"

opts = { port: 0, delay_ms: 10, stats_file: nil }
OptionParser.new do |o|
  o.on("--port N", Integer) { |v| opts[:port] = v }
  o.on("--delay-ms N", Integer) { |v| opts[:delay_ms] = v }
  o.on("--stats-file PATH") { |v| opts[:stats_file] = v }
end.parse!

server = DelayServer.new(port: opts[:port], delay_ms: opts[:delay_ms])

# Self-pipe: o handler de sinal só acorda o thread principal.
wake_r, wake_w = IO.pipe
%w[TERM INT].each { |sig| trap(sig) { wake_w.write_nonblock(".") rescue nil } }

Thread.new { server.serve }
$stdout.puts "PORT #{server.port}"
$stdout.flush

wake_r.read(1)
server.close
stats = server.stats
File.write(opts[:stats_file], JSON.generate(stats)) if opts[:stats_file]
$stderr.puts "delay_server: #{stats.except(:error_samples)}"
