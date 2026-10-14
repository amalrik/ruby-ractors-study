# frozen_string_literal: true

module BenchCommon
  # Resultado de uma execução de pool.
  #   startup_s  : criar workers até todos sinalizarem "pronto"
  #   process_s  : primeira tarefa enviada até a última resposta recebida
  #   shutdown_s : sinal de parada até todos os workers terminarem
  #   results    : { task_id => valor } (somente tarefas bem-sucedidas)
  #   latencies  : duração de cada tarefa medida dentro do worker (s)
  #   errors     : [[task_id, "Classe: mensagem"], ...]
  RunResult = Struct.new(:startup_s, :process_s, :shutdown_s, :results, :latencies, :errors,
                         keyword_init: true) do
    def total_s = startup_s + process_s + shutdown_s
  end

  # Formas de executar a mesma lista de tarefas com o mesmo handler.
  #
  # Contrato:
  #   tasks   : Array de [task_id, payload] (payload deve ser shareable/frozen)
  #   handler : Module com `call(payload, ctx)` -> resultado
  #             (Modules são shareable, então podem ser passados a Ractors)
  #   ctx     : Hash de configuração; será tornado shareable
  #
  # Os modos `fibers` e `ractor_fibers` usam a gem `async` (ver Gemfile).
  module Pools
    MODES = %w[sequential threads ractors fibers ractor_fibers].freeze

    # Executa uma tarefa e captura duração e erro. Chamado dentro do worker.
    def self.execute(handler, ctx, payload)
      t0 = Clock.now
      begin
        [:ok, handler.call(payload, ctx), Clock.now - t0]
      rescue StandardError => e
        [:error, "#{e.class}: #{e.message}", Clock.now - t0]
      end
    end

    def self.for(mode, ractors: nil)
      case mode
      when "sequential" then Sequential.new
      when "threads" then ThreadPool.new
      when "ractors" then RactorPool.new
      when "fibers" then FiberPool.new
      when "ractor_fibers" then RactorFiberPool.new(ractors: ractors)
      else raise ArgumentError, "modo desconhecido: #{mode} (use #{MODES.join(', ')})"
      end
    end

    # Coleta resultados de forma uniforme entre os modos.
    class Collector
      attr_reader :results, :latencies, :errors

      def initialize
        @results = {}
        @latencies = []
        @errors = []
      end

      def add(task_id, status, value, latency)
        @latencies << latency
        if status == :ok
          @errors << [task_id, "DuplicateResult"] if @results.key?(task_id)
          @results[task_id] = value
        else
          @errors << [task_id, value]
        end
      end
    end

    class Sequential
      def run(tasks, handler:, ctx:, workers: 1, **)
        raise ArgumentError, "sequential usa 1 worker" unless workers == 1

        ctx = Ractor.make_shareable(ctx)
        col = Collector.new
        t0 = Clock.now
        tasks.each do |id, payload|
          col.add(id, *Pools.execute(handler, ctx, payload))
        end
        RunResult.new(startup_s: 0.0, process_s: Clock.now - t0, shutdown_s: 0.0,
                      results: col.results, latencies: col.latencies, errors: col.errors)
      end
    end

    # Pool idiomático de threads: uma fila compartilhada de jobs (pull).
    class ThreadPool
      def run(tasks, handler:, ctx:, workers:, **)
        ctx = Ractor.make_shareable(ctx)
        jobs = Thread::Queue.new
        out = Thread::Queue.new
        ready = Thread::Queue.new
        col = Collector.new

        t0 = Clock.now
        threads = Array.new(workers) do
          Thread.new do
            ready << true
            while (job = jobs.pop)
              id, payload = job
              out << [id, *Pools.execute(handler, ctx, payload)]
            end
          end
        end
        workers.times { ready.pop }
        t1 = Clock.now

        tasks.each { |t| jobs << t }
        tasks.size.times { col.add(*out.pop) }
        t2 = Clock.now

        jobs.close
        threads.each(&:join)
        t3 = Clock.now

        RunResult.new(startup_s: t1 - t0, process_s: t2 - t1, shutdown_s: t3 - t2,
                      results: col.results, latencies: col.latencies, errors: col.errors)
      end
    end

    # Pool de Ractors. Em Ruby 4.0 um Ractor::Port só pode ser lido pelo
    # Ractor que o criou, então não existe "fila compartilhada" entre
    # workers: o Ractor principal despacha cada tarefa para um worker
    # específico (via mailbox padrão do worker) e recebe as respostas num
    # Port próprio. `prefetch` controla quantas tarefas ficam em voo por
    # worker (1 = só envia a próxima após receber a resposta).
    class RactorPool
      def initialize(prefetch: 1)
        @prefetch = prefetch
      end

      def run(tasks, handler:, ctx:, workers:, prefetch: @prefetch)
        ctx = Ractor.make_shareable(ctx)
        out = Ractor::Port.new
        col = Collector.new

        t0 = Clock.now
        ractors = Array.new(workers) do |w|
          Ractor.new(out, w, handler, ctx, name: "worker-#{w}") do |port, wid, h, c|
            port << [:ready, wid]
            while (job = Ractor.receive) != :stop
              id, payload = job
              port << [:done, wid, id, *BenchCommon::Pools.execute(h, c, payload)]
            end
            :stopped
          rescue Exception => e # rubocop:disable Lint/RescueException
            # Sem isso o Ractor principal ficaria bloqueado em out.receive.
            port << [:fatal, wid, "#{e.class}: #{e.message}"]
            raise
          end
        end
        workers.times do
          kind, wid, msg = out.receive
          raise "worker #{wid} falhou na inicialização: #{msg}" unless kind == :ready
        end
        t1 = Clock.now

        pending = tasks.each
        remaining = tasks.size
        ractors.each do |r|
          prefetch.times do
            r.send(pending.next)
          rescue StopIteration
            break
          end
        end
        while remaining.positive?
          kind, wid, *rest = out.receive
          raise "worker #{wid} morreu: #{rest.first}" if kind == :fatal

          col.add(*rest)
          remaining -= 1
          begin
            ractors[wid].send(pending.next)
          rescue StopIteration
            nil
          end
        end
        t2 = Clock.now

        ractors.each { |r| r.send(:stop) }
        ractors.each(&:join)
        out.close
        t3 = Clock.now

        RunResult.new(startup_s: t1 - t0, process_s: t2 - t1, shutdown_s: t3 - t2,
                      results: col.results, latencies: col.latencies, errors: col.errors)
      end
    end

    # Pool de Fibers sob o Fiber::Scheduler da gem `async`: uma única thread,
    # N fibers puxando de um índice compartilhado. Não precisa de lock: só
    # uma fiber executa por vez e a troca só ocorre em pontos de I/O/sleep.
    class FiberPool
      def run(tasks, handler:, ctx:, workers:, **)
        require "async"
        ctx = Ractor.make_shareable(ctx)
        col = Collector.new
        t0 = t1 = t2 = nil

        Sync do |parent|
          start = Async::Condition.new
          next_index = 0
          t0 = Clock.now
          # `async` executa cada fiber até o primeiro bloqueio, então ao fim
          # deste laço todas estão estacionadas em start.wait.
          fibers = Array.new(workers) do
            parent.async do
              start.wait
              while (i = next_index) < tasks.size
                next_index = i + 1
                id, payload = tasks[i]
                col.add(id, *Pools.execute(handler, ctx, payload))
              end
            end
          end
          t1 = Clock.now
          start.signal
          fibers.each(&:wait)
          t2 = Clock.now
        end
        t3 = Clock.now

        RunResult.new(startup_s: t1 - t0, process_s: t2 - t1, shutdown_s: t3 - t2,
                      results: col.results, latencies: col.latencies, errors: col.errors)
      end
    end

    # Híbrido: R Ractors, cada um com seu próprio reator `async` e
    # workers/R fibers. As tarefas são particionadas estaticamente
    # (round-robin) e entregues como argumento do Ractor, então não há
    # despachante central nem mensagem por tarefa; os resultados voltam em
    # bloco por Ractor#value.
    class RactorFiberPool
      def initialize(ractors: nil)
        require "etc"
        @ractors = ractors || Etc.nprocessors
      end

      def run(tasks, handler:, ctx:, workers:, **)
        require "async"
        ctx = Ractor.make_shareable(ctx)
        n = [@ractors, workers, tasks.size].min
        slices = Array.new(n) { [] }
        tasks.each_with_index { |t, i| slices[i % n] << t }
        fibers_per = Array.new(n) { |r| (workers / n) + (r < workers % n ? 1 : 0) }
        ready = Ractor::Port.new
        col = Collector.new

        t0 = Clock.now
        ractors = Array.new(n) do |r|
          Ractor.new(Ractor.make_shareable(slices[r]), fibers_per[r], handler, ctx, ready,
                     name: "rf-#{r}") do |slice, nfib, h, c, rdy|
            rdy << :ready
            Ractor.receive # sinal de início (ver nota no relatório sobre o M:N)
            out = []
            Sync do |parent|
              idx = 0
              Array.new(nfib) do
                parent.async do
                  while (i = idx) < slice.size
                    idx = i + 1
                    id, payload = slice[i]
                    out << [id, *BenchCommon::Pools.execute(h, c, payload)]
                  end
                end
              end.each(&:wait)
            end
            out
          end
        end
        n.times { ready.receive }
        t1 = Clock.now

        ractors.each { |rc| rc.send(:start) }
        ractors.each { |rc| rc.value.each { |row| col.add(*row) } }
        t2 = Clock.now
        ready.close

        RunResult.new(startup_s: t1 - t0, process_s: t2 - t1, shutdown_s: Clock.now - t2,
                      results: col.results, latencies: col.latencies, errors: col.errors)
      end
    end
  end
end
