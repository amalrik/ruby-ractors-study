# io_bound — espera controlada

Duas cargas, sempre rotuladas separadamente:

1. **`tcp` (benchmark de rede no loopback)** — `DelayServer` em processo
   separado (uma thread por conexão; o atraso é `sleep`, que libera o GVL).
   Cada operação: conecta, envia `"<id>\n"`, espera a resposta com timeout de
   5 s (`wait_readable`) e valida `"ok <id>\n"`. Erros e timeouts são contados.
   O servidor registra conexões aceitas, erros e concorrência máxima, para
   mostrar se ele virou gargalo.
2. **`sleep` (SIMULAÇÃO de espera, sem rede)** — a tarefa é só `sleep(delay)`.
   Isola o custo de agendamento de threads/Ractors do custo de sockets.

Padrão: 2.000 operações por repetição, atraso de 10 ms, concorrência
`8 / 32 / 128 / 256`; sequencial com 3 repetições (≈21 s cada), demais com 5.

## Comandos

```sh
ruby io_bound/bin/bench.rb                       # tcp + sleep, todos os modos
ruby io_bound/bin/bench.rb --quick
ruby io_bound/bin/bench.rb --workloads tcp --workers 16,64 --ops 1000
ruby io_bound/bin/bench.rb --workloads tcp --modes ractors --env RUBY_MAX_CPU=256

# servidor manual + um caso isolado
ruby io_bound/bin/delay_server.rb --delay-ms 10 --port 9500 &
ruby io_bound/bin/run_case.rb --workload tcp --port 9500 --mode threads --workers 32
ruby io_bound/bin/run_case.rb --workload tcp --port 9500 --mode ractors --workers 32
ruby io_bound/bin/run_case.rb --workload sleep --mode ractors --workers 32
kill %1

# reprodução isolada do limite de I/O com timeout em Ractors
ruby io_bound/bin/repro_ractor_io_timeout.rb 64 400
RUBY_MAX_CPU=64 ruby io_bound/bin/repro_ractor_io_timeout.rb 64 400

# gatilho mínimo: Ractor que espera Ractor.receive antes do I/O com timeout
ruby io_bound/bin/repro_ractor_receive_first.rb direct
ruby io_bound/bin/repro_ractor_receive_first.rb receive-first
```

Opções de `run_case.rb`: `--workload tcp|sleep`, `--mode`, `--workers`,
`--ops`, `--delay-ms`, `--host`, `--port`, `--timeout`, `--warmup`, `--reps`,
`--prefetch`.

## Fibers e híbrido

Os modos `fibers` (gem `async`, uma thread) e `ractor_fibers` (R Ractors,
cada um com seu reator `async`; use `--ractors N`) também estão disponíveis
aqui:

```sh
bundle install
ruby io_bound/bin/bench.rb --modes sequential,threads,ractors,fibers,ractor_fibers --ractors 8
```

O cenário mais representativo para Fibers é `smtp_sessions/` (conexões
longas com várias etapas).
