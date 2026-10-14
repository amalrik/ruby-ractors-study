# frozen_string_literal: true

require "socket"

# Cliente de uma sessão completa. Payload = id da sessão. Toda leitura tem
# timeout (IO#timeout), como um cliente/servidor SMTP real precisaria.
module SessionClient
  class ProtocolError < StandardError; end

  def self.call(id, ctx)
    timeout = ctx[:timeout_s]
    sock = TCPSocket.new(ctx[:host], ctx[:port], connect_timeout: timeout)
    sock.timeout = timeout
    begin
      expect(sock, "220")
      command(sock, "EHLO client-#{id}", "250")
      command(sock, "MAIL FROM:<s#{id}@poc.invalid>", "250")
      command(sock, "RCPT TO:<r#{id}@poc.invalid>", "250")
      command(sock, "DATA", "354")
      sock.write(ctx[:body])
      sock.write(".\r\n")
      expect(sock, "250 queued #{ctx[:body].bytesize}")
      command(sock, "QUIT", "221")
      # Por padrão espera o servidor fechar primeiro: o TIME_WAIT fica do lado
      # dele e o cliente não esgota portas efêmeras. Com NAT doméstico que
      # reaproveita portas, isso pode fazer SYNs novos caírem em TIME_WAIT no
      # servidor; `client_closes_first` inverte a ordem.
      raise ProtocolError, "dados após 221" unless ctx[:client_closes_first] || sock.gets.nil?

      id
    ensure
      sock.close
    end
  end

  def self.command(sock, line, code)
    sock.write("#{line}\r\n")
    expect(sock, code)
  end

  def self.expect(sock, prefix)
    line = sock.gets
    raise ProtocolError, "conexão fechada esperando #{prefix}" if line.nil?
    raise ProtocolError, "esperava #{prefix}, recebeu #{line.chomp}" unless line.start_with?(prefix)

    line
  end

  # Corpo parecido com email: linhas de 76 caracteres terminadas em CRLF.
  def self.build_body(bytes)
    line = "#{'x' * 76}\r\n"
    count = [(bytes.to_f / line.bytesize).ceil, 1].max
    (line * count).freeze
  end
end
