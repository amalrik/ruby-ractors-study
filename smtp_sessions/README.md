# smtp_sessions — sessões longas parecidas com SMTP

Carga mais próxima de um servidor de email do que o `io_bound/`. Cada
operação é uma **sessão** com várias idas e voltas na mesma conexão TCP:

```
220 → EHLO/250 → MAIL/250 → RCPT/250 → DATA/354 → corpo + "."/250 queued <bytes> → QUIT/221
```

- O servidor espera `--delay-ms` (padrão 10 ms) antes de **cada** resposta.
  São 7 respostas, então uma sessão leva ≈75 ms mais o processamento.
- Toda leitura do cliente tem timeout (`IO#timeout`) e cada resposta é
  validada; o servidor confere o número de bytes do corpo.
- **Não é SMTP** (sem RFC 5321, sem TLS, sem pipelining). Imita só o
  formato do diálogo.

## Servidor (`bin/session_server.rb`)

Motores (`--engine`), com `--workers N` para os de vários processos/Ractors:

| Motor | Desenho |
|---|---|
| `threads` | 1 processo, uma Thread por conexão |
| `fibers` | 1 processo, uma Fiber (`async`) por conexão |
| `prefork_threads` | N processos (fork) aceitando do mesmo socket; Thread por conexão |
| `prefork_fibers` | N processos (fork) aceitando do mesmo socket; Fiber por conexão (padrão) |
| `ractor_fibers` | 1 processo, N Ractors; cada um abre o próprio socket com `SO_REUSEPORT` e roda um reator `async` |

Ao receber TERM, o servidor informa sessões, erros, bytes, concorrência
máxima, sessões por worker, **CPU e RSS de pico** dos seus processos e o
**steal** da máquina.

## Comparar modelos de servidor (`bin/server_bench.rb`)

O servidor é o sistema medido, e o gerador de carga é fixo (cliente
`ractor_fibers`). Ele pode rodar local ou com o servidor num VPS via SSH
(passo a passo em [`../deploy/README.md`](../deploy/README.md)):

```sh
ruby smtp_sessions/bin/server_bench.rb --quick
ruby smtp_sessions/bin/server_bench.rb --engines threads,fibers,prefork_fibers,ractor_fibers --workers 100,1000,5000
ruby smtp_sessions/bin/server_bench.rb --remote bench@IP --workers 100,500,1000 --timeout 30
```

## Modos do cliente

| Modo | Desenho |
|---|---|
| `threads` | uma thread por sessão simultânea, com fila compartilhada |
| `fibers` | uma thread só, com N Fibers sob o `Fiber::Scheduler` do `async` |
| `ractor_fibers` | R Ractors (`--ractors`), cada um com um reator `async` e N/R Fibers; tarefas particionadas sem despachante |
| `ractors` | um Ractor por sessão simultânea (despachante central). Limitado a ~`RUBY_MAX_CPU` sessões e **instável** na 4.0.x; ver o relatório |

## Comandos

```sh
bundle install                                      # gem async (uma vez)

ruby smtp_sessions/bin/bench.rb                     # 100, 1k, 5k e 10k sessões simultâneas
ruby smtp_sessions/bin/bench.rb --quick
ruby smtp_sessions/bin/bench.rb --workers 20000 --modes threads,fibers --server-procs 8

# servidor manual + um caso
ruby smtp_sessions/bin/session_server.rb --procs 4 --delay-ms 10 --port 2525 &
ruby smtp_sessions/bin/run_case.rb --port 2525 --mode fibers --workers 1000
kill %1

# servidor em OUTRA máquina (ex.: dois VPS na mesma rede privada)
#   na máquina B: ruby smtp_sessions/bin/session_server.rb --host 0.0.0.0 --port 2525 --procs 8
#   na máquina A:
ruby smtp_sessions/bin/bench.rb --host 10.0.0.2 --port 2525

# travamento/crash de Ractors com sockets (Ruby 4.0.x)
smtp_sessions/bin/capture_hang.sh 10 25 prefork_fibers      # captura backtrace com gdb
ruby smtp_sessions/bin/repro_ractor_session_hang.rb real
```

Com `--host` o orquestrador **não** sobe servidor local nem coleta as
estatísticas dele; o servidor remoto as imprime no stderr ao receber TERM.

## Ajustes de sistema para 10k+ conexões

- `ulimit -n`: pelo menos 2 × o número de sessões simultâneas, mais uma
  margem (cliente e servidor na mesma máquina).
- `net.core.somaxconn` e `net.ipv4.tcp_max_syn_backlog`: pelo menos o número
  de sessões que conectam ao mesmo tempo. Se ficarem pequenos, o SYN é
  descartado e o cliente espera a retransmissão (1 s, 3 s, ...), o que
  aparece como um p99 de ~1 s.
- `net.ipv4.ip_local_port_range` e `net.ipv4.tcp_tw_reuse=1` quando o
  servidor está em outra máquina; o valor 2 (padrão) só reaproveita no
  loopback.
