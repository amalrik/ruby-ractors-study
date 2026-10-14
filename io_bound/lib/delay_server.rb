# frozen_string_literal: true

require "socket"
require "json"

# Servidor TCP local que responde após um atraso configurável.
#
# Protocolo (uma operação por conexão):
#   cliente -> "<id>\n"
#   servidor espera delay_ms e responde "ok <id>\n", depois fecha.
#
# Uma thread por conexão: o atraso é um `sleep`, que libera o GVL, então
# o servidor consegue manter centenas de esperas simultâneas sem ser o
# gargalo. Roda num processo separado dos clientes para não disputar o
# GVL com eles. Registra concorrência máxima observada e erros.
class DelayServer
  attr_reader :port

  def initialize(host: "127.0.0.1", port: 0, delay_ms: 10, backlog: 4096)
    @delay = delay_ms / 1000.0
    @server = TCPServer.new(host, port)
    @server.listen(backlog)
    @port = @server.addr[1]
    @lock = Mutex.new
    @stats = { accepted: 0, completed: 0, errors: 0, current: 0, max_concurrent: 0, error_samples: [] }
  end

  def stats = @lock.synchronize { @stats.dup }

  def serve
    loop do
      client = @server.accept
      track { |s| s[:accepted] += 1; s[:current] += 1; s[:max_concurrent] = [s[:max_concurrent], s[:current]].max }
      Thread.new(client) { |c| handle(c) }
    end
  rescue IOError, Errno::EBADF
    nil # servidor fechado
  end

  def close = @server.close

  private

  def handle(client)
    line = client.gets
    raise "requisição vazia" if line.nil?

    sleep @delay
    client.write("ok #{line.strip}\n")
    track { |s| s[:completed] += 1 }
  rescue StandardError => e
    track { |s| s[:errors] += 1; s[:error_samples] << "#{e.class}: #{e.message}" if s[:error_samples].size < 5 }
  ensure
    client&.close
    track { |s| s[:current] -= 1 }
  end

  def track
    @lock.synchronize { yield @stats }
  end
end
