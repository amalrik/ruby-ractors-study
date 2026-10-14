# frozen_string_literal: true

require "socket"

# Operações I/O-bound executadas pelos workers. Payload = id da operação.
module IoOps
  class Timeout < StandardError; end

  # Operação real de rede no loopback: conecta, envia o id, espera a
  # resposta do DelayServer e valida o conteúdo.
  module TcpHandler
    def self.call(id, ctx)
      timeout = ctx[:timeout_s]
      sock = TCPSocket.new(ctx[:host], ctx[:port], connect_timeout: timeout)
      begin
        sock.write("#{id}\n")
        raise IoOps::Timeout, "timeout esperando resposta (#{timeout}s)" unless sock.wait_readable(timeout)

        line = sock.gets
        raise "resposta inválida: #{line.inspect}" unless line == "ok #{id}\n"

        id
      ensure
        sock.close
      end
    end
  end

  # SIMULAÇÃO de espera (sem rede): apenas sleep. Serve para isolar o
  # custo de agendamento do custo de sockets; não é benchmark de rede.
  module SleepHandler
    def self.call(id, ctx)
      sleep ctx[:delay_s]
      id
    end
  end

  HANDLERS = { "tcp" => TcpHandler, "sleep" => SleepHandler }.freeze
end
