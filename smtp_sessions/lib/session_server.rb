# frozen_string_literal: true

require "async"
require "json"
require "socket"

# Servidor de sessões "parecidas com SMTP". NÃO é SMTP: só imita o formato
# do diálogo (linhas, códigos, DATA terminado em ".").
#
#   S: 220 ready                         (após delay)
#   C: EHLO x        S: 250 ok            (após delay)
#   C: MAIL FROM:<>  S: 250 ok            (após delay)
#   C: RCPT TO:<>    S: 250 ok            (após delay)
#   C: DATA          S: 354 go            (após delay)
#   C: <linhas> .    S: 250 queued <bytes> (após delay)
#   C: QUIT          S: 221 bye           (após delay) e fecha
#
# É o SISTEMA SOB TESTE quando comparamos modelos de servidor
# (bin/server_bench.rb) e o gerador de carga quando comparamos clientes
# (bin/bench.rb). Motores (`engine`):
#
#   threads          1 processo, 1 Thread por conexão
#   fibers           1 processo, 1 Fiber (`async`) por conexão
#   prefork_threads  N processos (fork) aceitando do mesmo socket; Thread por conexão
#   prefork_fibers   N processos (fork) aceitando do mesmo socket; Fiber por conexão
#   ractor_fibers    1 processo, N Ractors; cada um abre o PRÓPRIO socket com
#                    SO_REUSEPORT (o kernel distribui as conexões) e roda um
#                    reator `async` com uma Fiber por conexão
module SessionServer
  ENGINES = %w[threads fibers prefork_threads prefork_fibers ractor_fibers].freeze
  # nomes usados antes da versão plugável
  ALIASES = { "async" => "prefork_fibers" }.freeze

  # Protocolo, sem estado de instância: pode ser chamado de dentro de Ractors.
  module Protocol
    # Timeout de leitura do servidor: conexões ociosas/abandonadas são
    # encerradas (servidores SMTP reais também têm esse limite).
    IDLE_TIMEOUT_S = 60

    def self.new_stats
      { sessions: 0, errors: 0, current: 0, max_concurrent: 0, bytes: 0, error_samples: [] }
    end

    def self.reply(client, line, delay)
      sleep delay
      client.write("#{line}\r\n")
    end

    def self.handle(client, stats, delay)
      client.timeout = IDLE_TIMEOUT_S
      reply(client, "220 ready", delay)
      while (line = client.gets)
        case line.chomp
        when /\AEHLO /, /\AMAIL FROM:/, /\ARCPT TO:/ then reply(client, "250 ok", delay)
        when "DATA"
          reply(client, "354 go", delay)
          bytes = 0
          while (body = client.gets) && body != ".\r\n"
            bytes += body.bytesize
          end
          stats[:bytes] += bytes
          reply(client, "250 queued #{bytes}", delay)
        when "QUIT"
          reply(client, "221 bye", delay)
          stats[:sessions] += 1
          break
        else
          reply(client, "500 unknown", delay)
        end
      end
    rescue StandardError => e
      stats[:errors] += 1
      stats[:error_samples] << "#{e.class}: #{e.message}" if stats[:error_samples].size < 5
    ensure
      client.close
    end

    def self.opened(stats)
      stats[:current] += 1
      stats[:max_concurrent] = stats[:current] if stats[:current] > stats[:max_concurrent]
    end

    # Soma estatísticas de vários workers (processos ou Ractors).
    def self.merge(list)
      {
        sessions: list.sum { |s| s[:sessions] }, errors: list.sum { |s| s[:errors] },
        bytes: list.sum { |s| s[:bytes] },
        # soma dos máximos de cada worker: limite superior da concorrência total
        max_concurrent: list.sum { |s| s[:max_concurrent] },
        per_worker_sessions: list.map { |s| s[:sessions] },
        error_samples: list.flat_map { |s| s[:error_samples] }.first(5)
      }
    end
  end

  # Laços de um único processo/Ractor. Todos bloqueiam até `stop_io`
  # ficar legível e devolvem as estatísticas.
  module Loops
    # Socket#accept devolve [socket, Addrinfo]; TCPServer#accept, só o socket.
    def self.accept(listener)
      client, = listener.accept
      client
    end

    def self.fibers(listener, delay, stop_io)
      stats = Protocol.new_stats
      connections = {}
      Sync do |task|
        acceptor = task.async do
          loop do
            client = accept(listener)
            Protocol.opened(stats)
            conn = task.async do
              Protocol.handle(client, stats, delay)
            ensure
              stats[:current] -= 1
              connections.delete(conn)
            end
            connections[conn] = true unless conn.finished?
          end
        end
        stop_io.wait_readable
        acceptor.stop
        # Não espera conexões abertas (ex.: clientes que sumiram): encerra todas.
        connections.keys.each(&:stop)
      end
      stats
    end

    def self.threads(listener, delay, stop_io)
      stats = Protocol.new_stats
      lock = Mutex.new
      acceptor = Thread.new do
        loop do
          client = accept(listener)
          lock.synchronize { Protocol.opened(stats) }
          Thread.new(client) do |c|
            local = Protocol.new_stats
            Protocol.handle(c, local, delay)
          ensure
            lock.synchronize do
              stats[:current] -= 1
              %i[sessions errors bytes].each { |k| stats[k] += local[k] }
              stats[:error_samples].concat(local[:error_samples]).slice!(5..)
            end
          end
        end
      rescue IOError, Errno::EBADF
        nil # listener fechado no encerramento
      end
      stop_io.wait_readable
      listener.close
      acceptor.join(1)
      lock.synchronize { stats.dup }
    end
  end

  def self.status_kb(field)
    File.foreach("/proc/self/status").find { |l| l.start_with?("#{field}:") }&.split&.[](1)&.to_i
  rescue Errno::ENOENT
    nil
  end

  def self.process_metrics
    t = Process.times
    { cpu_s: t.utime + t.stime, peak_rss_kb: status_kb("VmHWM") }
  end

  # Servidor em execução: `start` abre os sockets e sobe os workers;
  # `stop` encerra tudo e devolve as estatísticas agregadas.
  class Runner
    attr_reader :port, :engine

    def initialize(engine:, host: "127.0.0.1", port: 0, delay_ms: 10, workers: 4, backlog: 65_535)
      @engine = ALIASES.fetch(engine, engine)
      raise ArgumentError, "engine desconhecido: #{engine} (#{ENGINES.join(', ')})" unless ENGINES.include?(@engine)

      @host = host
      @port = port
      @delay = delay_ms / 1000.0
      @workers = @engine.start_with?("prefork", "ractor") ? workers : 1
      @backlog = [backlog, Socket::SOMAXCONN].max
      @stop_r, @stop_w = IO.pipe
    end

    def start
      case @engine
      when "threads", "fibers" then start_single
      when "prefork_threads", "prefork_fibers" then start_prefork
      when "ractor_fibers" then start_ractors
      end
      self
    end

    def stop
      @stop_w.write(".") # todos os workers esperam este pipe ficar legível
      stats =
        case @engine
        when "threads", "fibers" then stop_single
        when "prefork_threads", "prefork_fibers" then stop_prefork
        when "ractor_fibers" then stop_ractors
        end
      stats.merge(engine: @engine, workers: @workers)
    end

    private

    def listen(reuseport: false)
      sock = Socket.new(:INET, :STREAM)
      sock.setsockopt(:SOCKET, :REUSEADDR, true)
      sock.setsockopt(:SOCKET, :REUSEPORT, true) if reuseport
      sock.bind(Addrinfo.tcp(@host, @port))
      sock.listen(@backlog)
      @port = sock.local_address.ip_port
      sock
    end

    # --- 1 processo ---
    def start_single
      @listener = listen
      inner = @engine == "fibers" ? :fibers : :threads
      @thread = Thread.new { Loops.public_send(inner, @listener, @delay, @stop_r) }
    end

    def stop_single
      Protocol.merge([@thread.value]).merge(SessionServer.process_metrics)
    end

    # --- prefork ---
    def start_prefork
      @listener = listen
      inner = @engine == "prefork_fibers" ? :fibers : :threads
      @children = Array.new(@workers) do
        r, w = IO.pipe
        pid = fork do
          r.close
          stats = Loops.public_send(inner, @listener, @delay, @stop_r)
          w.write(JSON.generate(stats.merge(SessionServer.process_metrics)))
          w.close
          exit!(0)
        end
        w.close
        [pid, r]
      end
      @listener.close # só os filhos aceitam
    end

    def stop_prefork
      list = @children.map do |pid, r|
        data = r.read
        Process.wait(pid)
        JSON.parse(data, symbolize_names: true)
      end
      own = SessionServer.process_metrics
      Protocol.merge(list).merge(
        cpu_s: list.sum { |s| s[:cpu_s] } + own[:cpu_s],
        # soma dos picos de cada processo (superestima páginas compartilhadas por COW)
        peak_rss_kb: list.sum { |s| s[:peak_rss_kb].to_i } + own[:peak_rss_kb].to_i
      )
    end

    # --- Ractors com SO_REUSEPORT ---
    def start_ractors
      # Descobre a porta (se 0) com um socket REUSEPORT, deixa os Ractors
      # abrirem os seus e só então fecha este, para nenhuma conexão cair nele.
      probe = listen(reuseport: true)
      ready = Ractor::Port.new
      stop_fd = @stop_r.fileno
      @ractors = Array.new(@workers) do |i|
        Ractor.new(@host, @port, @backlog, @delay, stop_fd, ready, name: "srv-#{i}") do |host, port, backlog, delay, fd, rdy|
          sock = Socket.new(:INET, :STREAM)
          sock.setsockopt(:SOCKET, :REUSEADDR, true)
          sock.setsockopt(:SOCKET, :REUSEPORT, true)
          sock.bind(Addrinfo.tcp(host, port))
          sock.listen(backlog)
          rdy << :listening
          stop_io = IO.for_fd(fd, autoclose: false)
          SessionServer::Loops.fibers(sock, delay, stop_io)
        end
      end
      @workers.times { ready.receive }
      probe.close
    end

    def stop_ractors
      Protocol.merge(@ractors.map(&:value)).merge(SessionServer.process_metrics)
    end
  end
end
