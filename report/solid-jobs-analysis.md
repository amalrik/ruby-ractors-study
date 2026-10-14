# Análise: nicolasva/solid-jobs × achados desta POC

Fonte lida em 2026-10-13: <https://github.com/nicolasva/solid-jobs> (commit
`58dd611`, 7 estrelas, licença **LGPL-3.0**) e o cliente Redis do mesmo autor,
<https://github.com/nicolasva/solid-redis>. O código foi **lido, não executado**:
os testes deles exigem Redis e as gems do autor.

## O que o projeto é

É um executor de tarefas para Ruby, orientado a Ractors e baseado em Redis.
É deliberadamente incompatível com o Sidekiq.

- **Unidade de execução:** um *Conductor* cria N Ractors *Engine*
  (`concurrency`, padrão 8), mais um Ractor de heartbeat e um de agendamento.
  Cada Engine executa **uma tarefa por vez**.
- **Distribuição de trabalho:** cada Engine **puxa direto do Redis**, com
  claim atômico em Lua. Não há despachante central e não há mensagens de
  tarefa entre Ractors.
- **Controle:** dentro de cada Engine, uma `Thread` auxiliar fica bloqueada em
  `Ractor.receive`, esperando comandos (`:quiet`/`:stop`). A thread principal
  executa o laço de trabalho.
- **Inicialização:** uma `StartupBarrier`, em que cada Ractor anuncia
  `:ready` numa `Ractor::Port` e **espera** o `:start`.
- **Encerramento:** com prazo. O `:stop` é reenviado algumas vezes e, depois
  de `shutdown_timeout`, o Ractor é abandonado com log de erro.
- **Código que não pode rodar em Ractor:** um roteador heurístico manda a
  tarefa para um *warm worker*, um processo Rails separado, via socket Unix.
  Atende uma requisição por vez por worker.
- **Bug da VM documentado por eles:** deadlock do Ruby 3.4 quando a GC roda
  enquanto vários Ractors trocam mensagens movidas
  (`test/support/ractor_barrier_repro.rb`). Por isso exigem Ruby ≥ 4.0.

## Ideias que valem para o Mailractor

1. **[recomendação] A fila durável como fila compartilhada entre Ractors.**
   Cada worker reivindica trabalho no armazenamento (claim com fencing token),
   em vez de um despachante no Ractor principal. Isso contorna a falta de
   canal multi-consumidor (seção 6.3 do relatório) e já é o desenho previsto
   para o Mailractor: o spool como fonte da verdade.
2. **[recomendação] Barreira de inicialização e encerramento com prazo**,
   como `StartupBarrier` e `Conductor#stop`. Isso resolve o problema que
   tivemos de o Ractor principal ficar preso em `receive` quando um worker
   morre.
3. **[recomendação] Configuração local de cada Ractor**, montada a partir de
   um *snapshot* shareable (`Blueprint.from_ractor_snapshot`).
4. **[recomendação] Processo separado para código que não é Ractor-safe.**
   É o mesmo papel que este estudo sugere para o I/O: processo/threads/Fibers
   fora dos Ractors.

## Ele resolve as limitações que encontramos?

Não, e provavelmente é afetado por elas. **[hipótese]** O código deles não foi
executado; a avaliação vem da leitura do código e das reproduções desta POC.

| Limitação que encontramos | Situação no solid-jobs |
|---|---|
| I/O com timeout em Ractor que antes esperou em `Port`/`Ractor.receive` fica preso às threads compartilhadas do M:N (~`RUBY_MAX_CPU`) | **Mesmo padrão:** a Engine espera na `Port` da `StartupBarrier` e depois faz I/O no Redis com timeout (`read_timeout` via `wait_readable`; `IO.select` com prazo na escrita e no TLS). Reproduzimos que esperar numa `Port` dispara o limite (0,58 s contra 0,11 s, 10 threads nativas). Com `concurrency` ≤ 8 isso não aparece; com mais Engines, ou tarefas de I/O com timeout dentro da Engine, a vazão deve travar em ~8. |
| Uma tarefa por Ractor: concorrência de I/O = número de Ractors | **Igual.** Não há Fibers nem threads de trabalho dentro da Engine. Tarefas de I/O (como enviar email) ficam limitadas a N Ractors, ou vão para o *warm worker*, que atende uma por vez. |
| Falta de fila multi-consumidor entre Ractors | **Contornada** com o Redis. |
| Travamentos/crash intermitentes com sockets em Ractors (Ruby 4.0.6; seção 8 do relatório) | **Não avaliado.** Eles testam na 4.0.7 e documentam outro bug da VM (3.4). O risco é o mesmo: VM ainda instável com Ractors + I/O. |

## Possíveis contribuições

1. **Para o solid-jobs:** abrir uma issue com
   `io_bound/bin/repro_ractor_receive_first.rb`, mostrando que Engines com
   `concurrency > RUBY_MAX_CPU` (ou tarefas com I/O temporizado) ficam
   limitadas a ~8.
   - Sugestões: documentar `RUBY_MAX_CPU`; medir `--concurrency 16/32` com
     tarefas de I/O; considerar Fibers (`async`) dentro da Engine.
   - Antes, convém rodar o benchmark deles (`benchmark/cpu_scaling.rb`) com
     uma tarefa de I/O para confirmar.
2. **Para o Ruby (bugs.ruby-lang.org), mais valioso:**
   - (a) o limite de I/O com timeout após `receive` no escalonador M:N;
   - (b) os travamentos e o `[BUG] double free` em sockets dentro de Ractors
     na 4.0.6, se ainda reproduzirem na 4.0.7 e na 4.1 (ver seção 8 do
     relatório).
3. **Não recomendado agora:** adotar o solid-jobs como base. O projeto é
   jovem (7 estrelas), a licença LGPL-3.0 exige atenção, e ele não resolve o
   caso de I/O, que é o centro de um servidor de email.
