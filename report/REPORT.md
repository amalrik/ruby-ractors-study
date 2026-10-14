# Relatório: threads vs. Ractors (POC Mailractor)

Data das medições: 2026-10-13 e 2026-10-14. Todos os números abaixo vêm dos
arquivos em `cpu_bound/results/`, `io_bound/results/` e
`smtp_sessions/results/`, citados por diretório.
Legenda: **[medido]** = fato observado nesta máquina; **[hipótese]** = explicação
plausível, ainda não verificada; **[recomendação]** = sugestão de engenharia.

> **Atualização de 2026-10-14 (leia primeiro).** As seções 3 a 7 descrevem a
> primeira rodada, feita em Ruby 4.0.6. A seção 8 acrescenta:
>
> - Fibers (`async`);
> - um modo híbrido Ractors + Fibers;
> - sessões de várias etapas parecidas com SMTP, com até 10 mil simultâneas;
> - dois bugs da VM em Ractors com sockets na 4.0.x: travamentos e um
>   `[BUG] double free` no GC;
> - a repetição das matrizes em **Ruby 4.1.0-preview1**.
>
> **Na 4.1 os problemas de Ractors com I/O desaparecem nos nossos testes**, e o
> híbrido Ractors + Fibers passa a ser o modelo de maior vazão. As conclusões
> da seção 5 valem para a 4.0.x; a seção 8.6 traz as conclusões atualizadas.

## 1. Ambiente

| Item | Valor |
|---|---|
| SO / kernel | Omarchy (Arch Linux), `Linux 7.2.8-5-omarchy-bore` x86_64 |
| CPU | AMD Ryzen 7 5700U (laptop): 8 núcleos físicos / 16 lógicos (SMT) |
| Frequência | driver `amd-pstate-epp`, governor `powersave`, EPP `balance_performance`, boost ligado, na tomada |
| Memória | 30 GiB |
| Ruby | `ruby 4.0.6 (2026-07-14 revision 03b6d3f889) +PRISM [x86_64-linux]`, CRuby, instalado via mise |
| JIT | YJIT compilado, **desligado** nas matrizes principais; ligado só no suplementar |
| API de Ractors | Ruby 4.0: `Ractor::Port`, `Ractor#join`, `Ractor#value`, `Ractor#monitor`; **sem** `Ractor.yield`/`Ractor#take`. Ainda emite `warning: Ractor API is experimental`. |
| Escalonador | M:N para Ractors não-principais; `RUBY_MAX_CPU` padrão (= 8 threads nativas) salvo indicação |
| Rede | só loopback; `tcp_tw_reuse=2`, portas efêmeras 32768–60999, `somaxconn=4096`, `nofile=524288` |
| Carga de fundo | load average ≈ 0,8–1,0 no início das matrizes (sessão desktop ativa) |

O ambiente completo de cada execução está em `results/<timestamp>/environment.json`.

## 2. Metodologia

- **Mesmo trabalho e a mesma validação em todos os modos.** Os pools ficam em
  `common/lib/bench_common/pools.rb` e o handler de cada carga é idêntico entre os modos.
  - `sequential`: laço no thread principal.
  - `threads`: pool idiomático com `Thread::Queue` compartilhada.
  - `ractors`: N Ractors workers. O Ractor principal despacha uma tarefa por
    vez para cada worker e recebe as respostas num `Ractor::Port`
    (`prefetch=1`, a menos que indicado).
- **Isolamento:** cada combinação (modo × workers × carga) roda num processo Ruby
  novo. Dentro dele há 1 aquecimento + 5 repetições (o I/O sequencial tem 3,
  porque cada uma leva ≈21 s). O pool é recriado a cada repetição.
- **Tempos separados:**
  - `startup` vai da criação dos workers até todos avisarem que estão prontos.
  - `process` vai do envio da primeira tarefa até a última resposta.
  - `shutdown` cobre o sinal de parada e o `join`.
  - Speedup e "total" usam a soma dos três.
- **Estatísticas:** mediana com mínimo e máximo das repetições medidas, sem o
  aquecimento. Latência p50/p95 por tarefa, medida dentro do worker.
- **CPU e memória:** `cpu_util` = (user + sys do processo) / tempo de parede, onde
  1,0 equivale a um núcleo cheio. RSS de pico (`VmHWM`) por processo, cobrindo
  aquecimento e repetições.
- **Não medido:** consumo de CPU e memória do servidor TCP, trocas de contexto,
  frequência real da CPU durante os testes, pausas de GC.
- **Incidente:** às 20:20:23 outra execução de `cpu_bound/bin/bench.rb` foi
  iniciada fora do script `run_all.sh` e rodou em paralelo com parte das
  medições. As execuções afetadas foram movidas para `results/discarded/` e
  refeitas às 20:32–20:37, sem concorrência. A seção TCP de
  `io_bound/results/20261013-201637` terminou antes disso e foi mantida (ver `NOTE.md` lá).

## 3. CPU-bound: contagem de primos

Configuração: intervalo `[0, 2.000.000)`, 148.933 primos, validados contra um
crivo de Eratóstenes. Os três tamanhos de bloco são 32 blocos de 62.500
números, 512 de 3.907 e 8.164 de 245 (≈0,4 ms por tarefa). Fonte:
`cpu_bound/results/20261013-200853/`. **Todos os casos foram válidos, sem erros.**

Tempo total (mediana, entre parênteses o mínimo e o máximo) e speedup em
relação ao sequencial do mesmo grupo:

| Blocos | Sequencial | Threads 8 | Threads 16 | Ractors 2 | Ractors 4 | Ractors 8 | Ractors 16 |
|---|---|---|---|---|---|---|---|
| 32 | 2,908 s | 3,035 s (0,96×) | 2,980 s (0,98×) | 1,620 s (1,80×) | 0,963 s (3,02×) | 0,620 s (4,69×) | 0,621 s (4,68×) |
| 512 | 3,173 s | 3,102 s (1,02×) | 3,026 s (1,05×) | 1,649 s (1,92×) | 0,945 s (3,36×) | **0,589 s (5,39×)** | 0,587 s (5,41×) |
| 8.164 | 3,121 s | 3,104 s (1,01×) | 3,128 s (1,00×) | 1,787 s (1,75×) | 0,980 s (3,18×) | 0,653 s (4,78×) | 0,602 s (5,19×) |

Observações:

1. **[medido]** Threads não aceleram nada. Com qualquer número de threads, o
   `cpu_util` fica em 1,00 e o tempo fica dentro de ±5% do sequencial.
   A latência p95 por tarefa explode (de 124 ms para 1.608 ms com 32 blocos e
   16 threads), porque as tarefas se intercalam disputando o GVL.
2. **[medido]** Ractors escalam até 8 workers, chegando a 5,4× com
   `cpu_util` ≈ 7,9. Com 16 workers não há ganho e o `cpu_util` continua
   ≈ 7,9 a 8,0, ou seja, só 8 threads nativas trabalham ao mesmo tempo.
3. **[medido]** Com `RUBY_MAX_CPU=16` (`cpu_bound/results/20261013-203556`),
   16 Ractors usam 14,95 CPUs, mas ficam **mais lentos** que 8: 0,701 s contra
   0,591 s, e o p50 por tarefa sobe de 9,5 para 22,5 ms. **[hipótese]** Os
   núcleos lógicos de SMT não rendem para esse laço de inteiros, e
   sobrecarregar a CPU só adiciona disputa.
4. **[medido]** Mesmo com 8 workers o speedup fica em 5,4×, não 8×. O p50
   por tarefa sobe de 6,5 ms (1 worker) para 9,4 ms (8 workers).
   **[hipótese]** O clock por núcleo cai quando todos os núcleos estão
   ocupados (laptop com boost e governor `powersave`); o custo de mensagens
   não explica, porque a tarefa em si fica mais lenta.
5. **Granularidade [medido]:**
   - Blocos grandes (32) perdem para 512 com 8 workers (4,69× contra 5,39×):
     4 blocos por worker e blocos altos mais caros deixam uma "cauda" no fim.
   - Blocos muito pequenos (8.164 tarefas de ≈0,4 ms) mostram o custo das
     mensagens: 1 Ractor fica 8% mais lento que o sequencial (3,365 s contra
     3,121 s), e 8 workers caem para 4,78×.
   - Com tarefas na casa de milissegundos, o overhead some.
6. **Custo de criar Ractors [medido]:**
   - O startup é pequeno: 0,1–0,5 ms para 1–16 workers, contra 0,2–1,3 ms
     para threads.
   - O RSS de pico fica em 18–24 MB em todos os modos.
   - Para CPU, criar Ractors **não** é o gargalo.
7. **YJIT** (suplementar, 512 blocos, `cpu_bound/results/20261013-203528`):
   - **[medido]** Funciona junto com Ractors e todos os casos foram válidos.
   - Sequencial: 0,448 s, 7× mais rápido que sem JIT.
   - Ractors 8: 0,105 s (4,27×). Threads continuam em ≈1,0×.
   - O speedup relativo cai porque as tarefas ficam ~7× menores, então o
     custo fixo de mensagens pesa mais.

## 4. I/O-bound: espera controlada

Configuração: 2.000 operações por repetição, atraso de 10 ms, timeout de 5 s.

**4.1 TCP no loopback** (`io_bound/results/20261013-201637`, seção `io_tcp`)

Uma conexão por operação, validando `"ok <id>"`. O servidor roda em outro processo.

| Modo | Workers | Total (mediana) | Vazão/s | p50 / p95 ms | Speedup | Conc. máx. no servidor |
|---|---|---|---|---|---|---|
| sequencial | 1 | 21,360 s | 93,6 | 10,66 / 10,84 | 1,00× | 2 |
| threads | 8 | 2,673 s | 748 | 10,65 / 11,05 | 7,99× | 12 |
| threads | 32 | 0,705 s | 2.847 | 11,06 / 11,93 | 30,3× | 45 |
| threads | 128 | 0,254 s | 8.176 | 15,19 / 18,52 | 84,1× | 139 |
| threads | 256 | 0,265 s | 8.258 | 28,51 / 34,11 | 80,8× | 248 |
| ractors | 8 | 2,722 s | 735 | 10,74 / 11,30 | 7,85× | 14 |
| ractors | 32 | 2,727 s | 734 | 10,72 / 11,54 | 7,83× | 14 |
| ractors | 128 | 2,752 s | 728 | 10,70 / 11,94 | 7,76× | 14 |
| ractors | 256 | 2,774 s | 724 | 10,68 / 12,36 | 7,70× | 15 |

**Todos os casos foram válidos, com 0 erros e 0 timeouts.** O servidor também não registrou erros.

- **[medido] Ractors com TCP não passam de ≈8 operações simultâneas,
  qualquer que seja o número de workers.** O servidor nunca vê mais que 14–15
  conexões, e a vazão fica em ≈730/s, igual à de 8 threads.
- **Causa isolada [medido]** com `io_bound/bin/repro_ractor_io_timeout.rb`
  (saída em `io_bound/results/repro_ractor_io_timeout.txt`), 64 workers, 400 operações:

  | Operação dentro do Ractor worker | Ractors (padrão) | Ractors `RUBY_MAX_CPU=64` | Threads |
  |---|---|---|---|
  | socket sem timeout | 0,097 s | 0,099 s | 0,084 s |
  | `TCPSocket.new(..., connect_timeout: 5)` | 0,088 s | 0,106 s | 0,082 s |
  | `IO#wait_readable(5)` | **0,555 s** | 0,085 s | 0,083 s |
  | `IO#timeout = 5` | **0,542 s** | 0,084 s | 0,083 s |

  No pool, leitura ou espera de I/O **com timeout** prende uma das
  `RUBY_MAX_CPU` threads nativas (padrão 8) do escalonador M:N. As mesmas
  operações sem timeout, e o `sleep`, não prendem.
- **Revisão do pool: o gatilho é ficar bloqueado em `Ractor.receive` antes do
  primeiro I/O [medido].** O pool foi revisado à procura de erro que
  bloqueasse o Ractor principal, e não há:
  - Um despachante equivalente, escrito do zero, atende 400 tarefas em
    ≈0,09 s quando o processo já tem threads nativas suficientes.
  - Trocar o `Enumerator#next` por índice não muda nada.

  A diferença está no runtime. Com `io_bound/bin/repro_ractor_receive_first.rb`
  (sem pool e sem despachante; 64 Ractors, 400 operações, um processo novo
  por rodada, saída em `io_bound/results/repro_ractor_receive_first.txt`):

  | Comportamento do Ractor | Tempo (3 rodadas) | Threads nativas no processo |
  |---|---|---|
  | começa direto no I/O com timeout | 0,110–0,117 s | 65–68 |
  | espera `Ractor.receive` e só depois faz I/O | 0,590–0,593 s | 10 |
  | idem, com uma espera de 1 ms num pipe antes do `receive` | 0,241–0,270 s | 22–24 |
  | idem ao segundo, com `RUBY_MAX_CPU=64` | 0,144 s | 66 |

  - Um Ractor que faz uma espera com timeout logo ao iniciar ganha uma thread
    nativa dedicada.
  - Um Ractor que já passou pelo escalonador M:N (por exemplo, esperando em
    `Ractor.receive`, como todo worker de pool) não ganha. A espera com
    timeout passa então a ocupar uma das ~8 threads compartilhadas.
  - As threads nativas criadas persistem no processo, então a ordem dos
    testes altera o resultado. Por isso cada caso roda num processo novo.

  **[hipótese]** A espera com timeout de uma thread M:N não é entregue ao
  event loop do escalonador. Falta confirmar no código do VM
  (`thread_pthread_mn.c`).
  Para um servidor de email isso é crítico: todo I/O de SMTP precisa de
  timeout, e todo worker de pool espera mensagens.
- **[medido] Aumentar `RUBY_MAX_CPU` ajuda só até certo ponto**
  (`io_bound/results/20261013-203414`, `RUBY_MAX_CPU=256`):

  | Ractors | Total | p50 / p95 ms | Conc. máx. no servidor |
  |---|---|---|---|
  | 32 | 0,715 s | 10,92 / 12,42 | 47 |
  | 128 | 0,727 s | 22,26 / 50,15 | 109 |
  | 256 | 0,925 s | 24,27 / 66,61 | 87 |

  Com 32 Ractors o resultado empata com 32 threads (0,705 s). A partir de 128
  piora: o p95 vai a 50–67 ms e o `cpu_util` a 2,4–2,6, contra 1,1 nas threads.
- **[medido] Threads saturam em ≈8.200 operações/s a partir de 128 workers,**
  e o p50 sobe para 28 ms com 256. **[hipótese]** O gargalo é o próprio
  gerador ou o servidor: um único processo com uma thread por conexão aceita
  ≈8 mil conexões novas por segundo sob o GVL. O CPU do servidor não foi
  medido, então esse platô não deve ser atribuído ao cliente.

**4.2 Simulação de espera com `sleep`, sem rede** (`io_bound/results/20261013-203207`)

Mede só o custo de agendamento. **Não é benchmark de rede.**

| Modo | Workers | Total (mediana) | Vazão/s | Speedup | RSS pico MB |
|---|---|---|---|---|---|
| sequencial | 1 | 20,360 s | 98 | 1,00× | 18,3 |
| threads | 32 | 0,644 s | 3.121 | 31,6× | 20,0 |
| threads | 128 | 0,178 s | 12.024 | 114,6× | 23,2 |
| threads | 256 | 0,106 s | 23.099 | 191,6× | 31,8 |
| ractors | 32 | 0,771 s | 2.602 | 26,4× | 20,8 |
| ractors | 128 | 0,239 s | 8.560 | 85,3× | 23,1 |
| ractors | 256 | 0,206 s | 10.280 | 98,7× | 24,5 |
| ractors, prefetch 4 | 128 | 0,187 s | 11.018 | — | 22,9 |
| ractors, prefetch 4 | 256 | 0,147 s | 14.739 | — | 25,7 |

(A linha de prefetch 4 vem de `io_bound/results/20261013-203656`.)

- **[medido]** Com `sleep`, os Ractors **escalam** além de 8 workers, ao
  contrário do TCP com timeout. Mesmo assim ficam abaixo das threads a partir
  de 32 workers: 10,3 mil contra 23,1 mil operações/s com 256.
- **[medido]** Aumentar o `prefetch` (tarefas em voo por worker) de 1 para 4
  melhora a vazão em 29–43%. **[hipótese]** O gargalo é o despacho
  centralizado no Ractor principal, com duas mensagens por tarefa
  serializadas num único Ractor. Isso se encaixa no fato de não existir fila
  compartilhada entre Ractors (ver seção 6).
- **[medido]** Criar 256 Ractors leva ≈11 ms (≈45 µs cada) e 256 threads
  ≈17 ms. O RSS de pico com 256 Ractors é **menor** que com 256 threads
  (24,5 contra 31,8 MB).

## 5. Conclusões práticas

> Valem para **uma** máquina (laptop de 8 núcleos), Ruby 4.0.6 e cargas
> sintéticas. Não são conclusões sobre produção.

**CPU-bound**
- **[medido]** Threads não servem para paralelizar Ruby puro (GVL).
- **[medido]** Ractors entregam 4,7–5,4× com 8 workers numa máquina de
  8 núcleos físicos, com startup e memória desprezíveis.
- **[medido]** Mais workers que núcleos físicos não ajudam. Com o padrão,
  `RUBY_MAX_CPU=8` limita; liberando 16, fica mais lento.
- **[recomendação]** Para etapas de CPU do pipeline (parse de MIME,
  assinatura e verificação, filtros, compressão), usar **um pool de Ractors
  do tamanho do número de núcleos físicos**, com tarefas de pelo menos
  alguns milissegundos ou agrupadas em lotes.
- **[recomendação]** Medir com as tarefas reais antes de decidir: código em C
  que libera o GVL, como OpenSSL, pode tornar threads suficientes. Isso
  **não foi medido aqui**.

**I/O-bound**
- **[medido]** Threads foram suficientes e melhores em todos os níveis de
  concorrência testados (até 256), com latência estável até 128.
- **[medido]** Ractors não trouxeram ganho em I/O e trouxeram um
  **risco sério**: I/O com timeout fica limitado a ~`RUBY_MAX_CPU`
  operações simultâneas. Aumentar o limite contorna em 32 workers, mas piora
  a partir de 128.
- **[recomendação]** Sessões SMTP, DNS e entrega devem usar threads (ou
  Fibers, ainda não medido) **dentro** de um processo ou Ractor. Não usar
  "um Ractor por conexão".
- **[recomendação]** Para o runtime de jobs, o modelo a prototipar em seguida
  é híbrido: a fila durável ou spool como fonte da verdade, poucos Ractors
  (≈ núcleos físicos) para estágios de CPU e threads para estágios de I/O.
  Mensagens entre Ractors **não** substituem a persistência.

**O que ainda precisa ser medido**
1. O modelo híbrido: Ractors com pools de threads internos, I/O fora dos Ractors.
2. Fibers com `Fiber::Scheduler` (gem `async`) contra threads para I/O.
3. Processos com fork/prefork como baseline, que é a alternativa clássica
   ao GVL e não foi comparada.
4. Cargas reais do pipeline: MIME, DKIM/OpenSSL, mensagens de 10 KB a 10 MB
   (custo de cópia ou `move:` entre Ractors).
5. Gerador de I/O que comprovadamente não seja gargalo (servidor
   multi-processo ou em outra máquina) e medição do CPU do servidor.
6. Servidor Linux de verdade (VPS ou bare metal) com frequência fixa,
   execuções mais longas e várias rodadas em dias diferentes.
7. Confirmação no código do CRuby, e eventual issue, do comportamento de
   `wait_readable(timeout)`/`IO#timeout` no escalonador M:N.

## 6. Dificuldades de API e ergonomia de Ractors (Ruby 4.0.6)

Insumo para uma possível contribuição à linguagem ou a bibliotecas.

1. **I/O com timeout fura o M:N [medido].** `IO#wait_readable(t)` e
   `IO#timeout=` limitam a concorrência a `RUBY_MAX_CPU` em Ractors que já
   esperaram em `Ractor.receive`, que é justamente o padrão de qualquer
   worker. Ractors recém-criados não sofrem isso, e o resultado depende de
   quantas threads nativas o processo já criou antes. Nada avisa: o
   programa só fica lento. Há duas reproduções mínimas:
   `io_bound/bin/repro_ractor_receive_first.rb` (o gatilho) e
   `io_bound/bin/repro_ractor_io_timeout.rb` (efeito no pool).
2. **`RUBY_MAX_CPU` é global, só configurável por variável de ambiente e o
   padrão (8) não segue `Etc.nprocessors` [medido].** Numa máquina de 16 CPUs
   lógicas, 16 Ractors de CPU usam só 8. Não há API em Ruby para consultar ou
   ajustar esse valor por pool.
3. **Não existe fila compartilhada ou work-stealing.** Em 4.0, um
   `Ractor::Port` só pode ser lido pelo Ractor que o criou. Um pool "pull" no
   estilo `Thread::Queue` precisa de um despachante central, e isso vira
   gargalo de vazão [medido no `sleep`: prefetch 4 dá até +43%]. Falta um
   canal multi-consumidor na stdlib (ou um `Ractor::Pool`).
4. **Pool, encerramento e erros são manuais.**
   - Não há pool pronto. O protocolo `:ready`/`:stop`/`join` e o fechamento
     do Port precisaram ser escritos à mão (`common/lib/bench_common/pools.rb`).
   - Se um worker morre enquanto o principal está bloqueado em
     `port.receive`, o principal **trava para sempre**. Foi preciso um
     `rescue Exception` no worker que envia `[:fatal, ...]` antes de relançar
     (`Ractor#monitor` existe, mas exige ainda mais código).
   - A exceção chega como `Ractor::RemoteError`, com a original em `#cause`,
     e ainda é impressa no stderr como `#<Thread:...> terminated with exception`.
5. **Isolamento só aparece em tempo de execução.**
   - Constantes com valor mutável (`CONST = [1, 2]`) geram
     `Ractor::IsolationError` só quando o worker as lê.
   - Blocos de `Ractor.new` não capturam variáveis externas, então tudo vai
     por argumento.
   - Configuração exige `Ractor.make_shareable`, e payloads precisam estar
     frozen.
   - Na prática os handlers viram `Module`s com métodos de módulo.
   - Tudo isso conflita com o código Ruby/Rails idiomático (configurações
     globais, caches em constantes, memoização em variáveis de classe).
6. **Cópia de mensagens.** Objetos não-shareable são copiados profundamente
   em cada `send`. Nesta POC os payloads são inteiros pequenos, então o custo
   **não foi medido**. Mensagens de email grandes vão exigir `move: true` ou
   dados frozen. Pendente.
7. **Instabilidade da API.** O Ruby 4.0 removeu `Ractor.yield`/`Ractor#take`
   e introduziu `Ractor::Port`. Código e gems feitos para 3.x não rodam sem
   mudanças. O aviso "experimental" continua a cada execução.
8. **`require` dentro de Ractors.** Tudo foi carregado no Ractor principal
   antes de criar os workers. Carregar código dentro de um Ractor não foi
   testado; o Ruby 4.0 tem `Ractor._require`, mas o comportamento com gems
   reais está pendente.
9. **Pontos positivos [medido].**
   - Criar Ractors é barato: ≈45 µs cada, com RSS menor que threads em 256 workers.
   - Sockets, `sleep` e YJIT funcionam dentro de Ractors.
   - Nomear Ractors (`name:`) ajuda a depurar.
   - O paralelismo real de CPU funciona sem alterar o algoritmo.

## 7. Limitações do benchmark

- **Escopo da máquina e do software:** uma máquina laptop, com governor
  `powersave` e boost ligado, sem fixar frequência nem afinidade de CPU, com o
  desktop ativo. Uma única versão de Ruby, sem repetir a matriz inteira em
  dias diferentes.
- **Cargas sintéticas:**
  - A divisão por tentativa é deliberadamente simples.
  - O I/O é uma conexão por operação, com respostas minúsculas e só no loopback.
  - O atraso é fixo (10 ms), sem variabilidade.
- **Servidor de I/O:** é Ruby em um processo, e pode limitar acima de
  ≈8 mil conexões por segundo. O CPU do servidor não foi medido.
- **Sobre o pool de Ractors:**
  - O desenho usado (despacho central, prefetch 1) é uma das opções possíveis.
  - Outros desenhos, como particionamento estático, prefetch maior ou lotes,
    mudam os números em tarefas pequenas.
- **Métricas:**
  - A latência por tarefa é medida dentro do worker e não inclui fila nem
    despacho.
  - O RSS é o pico do processo inteiro, não por repetição.
- Fibers e processos não foram comparados.

## 8. Fibers, sessões parecidas com SMTP e Ruby 4.1 (2026-10-14)

### 8.1 O que foi acrescentado

- **Modo `fibers`:** uma thread só, com N Fibers sob o `Fiber::Scheduler` da
  gem `async` 2.46 (`io-event` 1.22, seletor `io_uring`). É a primeira
  dependência externa da POC (`Gemfile`).
- **Modo `ractor_fibers`:** R Ractors (8 = núcleos físicos), cada um com seu
  reator `async` e N/R Fibers. As tarefas são particionadas sem despachante.
  **[medido]** O `async` funciona dentro de Ractors não-principais.
- **Projeto `smtp_sessions/`:** sessões com 7 idas e voltas na mesma conexão
  (banner, EHLO, MAIL, RCPT, DATA com 4 KB, QUIT), 10 ms de atraso em cada
  resposta e timeout em toda leitura. O servidor é prefork (4 processos) com
  `async` e informa a CPU que consumiu. Cliente e servidor rodam **na mesma
  máquina**.

### 8.2 Sessões: Ruby 4.0.6 × 4.1.0-preview1

Fontes: `smtp_sessions/results/20261014-001157` (4.0.6) e
`smtp_sessions/results/20261014-002112` (4.1.0-preview1). Valores: tempo total
(mediana de 3 repetições) / p99 da sessão / RSS de pico do cliente. A sessão
ideal leva ≈75 ms, mais o processamento.

| Sessões simultâneas | Modo | 4.0.6 | 4.1.0-preview1 |
|---|---|---|---|
| 100 | threads | 0,357 s / 118 ms / 30 MB | 0,361 s / 123 ms / 33 MB |
| 100 | fibers | 0,353 s / 120 ms / 32 MB | 0,358 s / 124 ms / 33 MB |
| 100 | ractor_fibers | 0,458 s / 125 ms / 34 MB | 0,456 s / 125 ms / 41 MB |
| 100 | ractors (1 Ractor por sessão) | **4,327 s** (≈8 simultâneas) | 0,580 s / 117 ms / 74 MB |
| 1.000 | threads | 0,852 s / 293 ms / 84 MB | 0,835 s / 278 ms / 87 MB |
| 1.000 | fibers | 0,899 s / 327 ms / 62 MB | 0,766 s / 309 ms / 64 MB |
| 1.000 | ractor_fibers | 1,202 s / **1.178 ms** | **0,422 s / 149 ms** / 71 MB |
| 5.000 | threads | 6,248 s / 1,8 s / 337 MB | 6,138 s / 1,9 s / 346 MB |
| 5.000 | fibers | 10,586 s / 3,7 s / 192 MB | 4,541 s / 1,8 s / 188 MB |
| 5.000 | ractor_fibers | **inválido**: 6.714 timeouts | **1,573 s / 555 ms** / 201 MB |
| 10.000 | threads | 19,122 s / 5,3 s / 646 MB | 17,559 s / 4,9 s / 662 MB |
| 10.000 | fibers | 40,393 s / 15,9 s / 358 MB | 9,984 s / 3,9 s / 344 MB |
| 10.000 | ractor_fibers | **inválido**: 19.974 timeouts | **4,625 s** / 3,2 s / 349 MB |

Observações:

1. **[medido] Até ~1.000 sessões, threads e Fibers empatam** e ficam perto do
   ideal com 100 sessões.
2. **[medido] Com 5 mil e 10 mil sessões, um único processo Ruby satura a
   CPU.**
   - Fibers usam ≈0,8–0,9 núcleo, ou seja, um núcleo cheio; threads usam
     ≈1,3–1,5, por causa do GVL e do tempo no kernel.
   - A latência passa a ser fila (lei de Little: em 4.0.6 com Fibers,
     10.000 ÷ 745/s ≈ 13 s, igual ao p50 medido).
   - O servidor gasta 30–76 s de CPU por caso na mesma máquina.
     **[hipótese]** Ele também disputa CPU; precisa de máquina separada (§ 8.5).
3. **[medido] Custo de memória e de criação:** com 10 mil sessões, threads
   usam 646–662 MB e levam **5,5–6,2 s** só para criar as threads. Fibers usam
   344–358 MB e levam 0,08–0,12 s.
4. **[medido] O híbrido Ractors + Fibers é o único modelo que usa vários
   núcleos** (`cpu_util` 3,2–4,6).
   - Na 4.1 foi o mais rápido em todos os níveis a partir de 1.000 sessões:
     2,0× threads com 1.000, 3,9× com 5.000 e 3,8× com 10.000.
   - Na 4.0.6 foi **inutilizável**: timeouts de 10 s em 22–28% das sessões com
     5 mil e 10 mil, e p95/p99 de ~1,1 s já com 1.000.
5. **[medido] As Fibers melhoraram muito na 4.1** com alta concorrência:
   10 mil sessões em 10,0 s contra 40,4 s na 4.0.6.
   **[hipótese]** Há mudanças no escalonador/`io-event` dessa versão.
6. **[medido] Com 10 mil sessões, mesmo na 4.1, o p95 do híbrido chega a
   2,5 s.** Ainda há disputa de CPU com o servidor; falta medir em máquinas
   separadas.

### 8.3 I/O TCP e CPU na 4.1.0-preview1

Fontes: `io_bound/results/20261014-002431` e
`cpu_bound/results/20261014-002906`.

- **[medido] Ractors puros com TCP passam a escalar.** Com 256 workers:
  7.622 operações/s e o servidor vendo 239 conexões simultâneas. Na 4.0.6
  eram 724/s e 15 conexões.
- **[medido] O limite "receive antes do I/O" sumiu**
  (`io_bound/bin/repro_ractor_receive_first.rb`): 0,104 s contra 0,588 s na
  4.0.7, com só ~18 threads nativas.
- **[medido] Fibers foram o modo de I/O mais eficiente:** 8.369 operações/s
  com 256 workers usando **0,57 núcleo**, contra 1,15 das threads e 1,21 dos
  Ractors.
- **[medido] O platô do despachante central** (simulação com sleep) também
  sumiu: Ractors com 256 workers chegam a 22.320/s, contra 10.280 na 4.0.6.
- **[medido] CPU:** igual à 4.0.6 com 8 workers (4,83×). Com 16 workers, o
  `cpu_util` chega a 15,0, então o limite padrão de threads nativas deixou de
  ser 8. Mesmo assim, 16 Ractors foram mais lentos que 8 (4,18×), como no
  experimento com `RUBY_MAX_CPU=16`.

### 8.4 Bugs da VM em Ractors com sockets (4.0.6 e 4.0.7)

**[medido]** Clientes de sessão no modo `ractors` (8 workers, um pool com
`Ractor::Port`) travam de forma intermitente: o processo fica parado
indefinidamente.

- **Estado capturado com gdb** (`smtp_sessions/bin/capture_hang.sh`;
  saídas em `smtp_sessions/results/hang-*/`):
  - as 8 threads nativas dos workers estão em `gets` →
    `nogvl_wait_for` → `poll` **com timeout**;
  - o Ractor principal espera em `Ractor::Port#receive`;
  - nos dois lados da conexão, as filas do kernel estão **vazias** e
    continuam vazias 5 s depois;
  - **o timeout de leitura nunca dispara.** Com `IO#timeout = 2` o
    processo ficou parado por 60 s.
- **Não depende do servidor:** reproduz tanto com o servidor `async` quanto
  com o de threads (`--engine threads`).
- **Crash:** uma das execuções terminou com
  `double free or corruption (!prev)` / `[BUG] Aborted`, **dentro do sweep do
  GC** (`gc_sweep_page` → `rb_gc_obj_free`). Isso aconteceu enquanto um
  Ractor worker alocava uma string em `sock.write("#{line}\r\n")`. Arquivo:
  `smtp_sessions/results/crash/abort-real-15.txt`.
  **[hipótese]** Os travamentos e o crash têm a mesma origem: corrupção de
  memória ligada a GC + Ractors + IO. Isso explicaria por que a variante
  sintética, que aloca menos e roda menos GC, quase nunca falha.
- **Frequência por versão** (`smtp_sessions/results/repro_ractor_session_hang_versions.txt`):

  | Ruby | Reprodutor (`repro_ractor_session_hang.rb real`) | Condições do benchmark (`run_case`) |
  |---|---|---|
  | 4.0.6 | 1/20 travamentos (+1 crash em outra rodada) | **6/20** travamentos |
  | 4.0.7 | 0/20 | **4/20** travamentos |
  | 4.1.0-preview1 | 0/20 | **0/20** |

  A 4.1.0-preview1 não apresentou nenhum caso em 40 tentativas. Pelas taxas da
  4.0.x, a chance disso ser sorte é pequena (<1%). Mesmo assim, é uma versão
  *preview*.

### 8.5 Limites desta rodada

- Cliente e servidor dividem os mesmos 16 CPUs lógicos. Com 5 mil sessões ou
  mais, o servidor consome dezenas de segundos de CPU por caso. As
  comparações entre modos continuam justas (mesmo servidor), mas a vazão
  absoluta está subestimada.
- O servidor prefork distribui as conexões entre os filhos pelo `accept`
  compartilhado. O equilíbrio entre os filhos não foi medido.
- `tcp_max_syn_backlog = 2048` nesta máquina. Picos de conexão acima disso
  podem descartar SYN e somar ~1 s ao p99. Isso não foi isolado.
- 3 repetições por caso com 5 mil e 10 mil sessões; uma única máquina; a
  4.1 é uma *preview*.

### 8.6 Conclusões atualizadas

- **[recomendação] Mirar Ruby ≥ 4.1 para usar Ractors com I/O.** Na 4.0.x
  (inclusive a 4.0.7, a mais recente estável), Ractors com sockets têm:
  - um limite de concorrência (§ 4.1);
  - **travamentos e corrupção de memória** (§ 8.4);
  - um híbrido com timeouts em massa (§ 8.2).

  Para produção na 4.0.x, usar Ractors **só para CPU puro**, sem sockets
  dentro deles.
- **[recomendação] Servidor SMTP de entrada:**
  - **Fibers (`async`) num processo** atendem até ~1.000 sessões
    simultâneas com folga e com metade da memória das threads.
  - Para escalar além de um núcleo, usar **Ractors + Fibers** (Ruby 4.1),
    ou o equivalente clássico, **processos (prefork) + Fibers**. O prefork
    funciona em qualquer versão e **não foi medido como cliente aqui**:
    é a próxima comparação obrigatória.
- **[recomendação] Threads servem até algumas centenas de conexões.** A
  partir de milhares, o custo de criação (segundos) e de memória (~65 KB por
  sessão) pesa.
- **[recomendação] Para pipelines de jobs:** spool durável como fonte da
  verdade, com cada worker reivindicando trabalho direto da fila (ideia
  validada no solid-jobs, ver `report/solid-jobs-analysis.md`). Ractors para
  estágios de CPU; Fibers para estágios de I/O.

### 8.7 Regressão encontrada na 4.1.0-preview1 (2026-10-14)

**[medido]** `Exception#detailed_message` (que usa `error_highlight` →
`RubyVM::AbstractSyntaxTree`) chamado em **2 ou mais Ractors ao mesmo tempo**
causa `[BUG] Segmentation fault` na 4.1.0-preview1.

- **Frequência:** 8/8 com 8 Ractors, 4/4 com 2 Ractors, 0/4 com 1 Ractor.
- **Na 4.0.6 e na 4.0.7, o mesmo script funciona.**
- **Pilha:** `vm_ic_update` → `rb_current_ractor` → SEGV no endereço 0x30.
- **Reprodutor sem gems:**
  `upstream/ruby-4.1-detailed-message-ractors/repro.rb` (saída do crash ao lado).

Como apareceu no benchmark: a gem `async` registra exceções de tarefas
(gem `console`) chamando `detailed_message`. Com `async` em vários Ractors
e tarefas que falham (`upstream/async-exceptions-in-ractors/repro.rb`):

- **4.1:** segfault em 1/5 execuções;
- **4.0.6:** trava em 5/5 (não diagnosticado).

**Impacto e ação:** o servidor `ractor_fibers` desta POC captura todas as
exceções no protocolo e guarda só a `message`, por isso não é afetado nas
medições. Num servidor real, qualquer log de exceção dentro de Ractors pode
derrubar o processo. **[recomendação]** Relatar ao bugs.ruby-lang.org
**antes do lançamento da 4.1**: é uma regressão, com reprodutor
determinístico e sem dependências.

## 9. Modelos de SERVIDOR num VPS (Hetzner CPX42, 2026-10-14)

Até aqui comparamos modelos de *cliente*. Nesta seção o **servidor** é o
sistema medido (`smtp_sessions/bin/server_bench.rb`); o gerador de carga é
fixo (cliente `ractor_fibers`, Ruby 4.1).

**Ambiente:** Hetzner Cloud CPX42, Helsinque. 8 vCPU AMD EPYC Genoa
(compartilhadas, 1 thread por núcleo), 15 GB, KVM, Ubuntu 24.04.4,
Ruby 4.1.0-preview1, `async` 2.46 com `io_uring`. Na mesma máquina:
servidor com 4 workers (processos ou Ractors) e gerador com 4 Ractors.
**Steal = 0,0%** em todas as 96 medições. Resultados em
`remote_results/hetzner-cpx42-hel1/smtp_sessions/20261014-154434` (rodada 1) e
`.../20261014-155112` (rodada 2); 3 repetições por caso.

### 9.1 Resultados (vazão em sessões/s; rodada 1 / rodada 2)

| Sessões simultâneas | threads | fibers | prefork_fibers (4 proc.) | ractor_fibers (4 Ractors) |
|---|---|---|---|---|
| 100 | 712 / – | 802 / – | 864 / – | 851 / – |
| 1.000 | 1.593 / 1.389 | 3.381 / 3.285 | **7.453 / 7.129** | 6.966 / 6.439 |
| 5.000 | 1.457 / 1.548 | 3.806 / 3.703 | **11.594 / 12.064** | 9.767 / 9.146 |
| 10.000 | – / 1.460 | – / 3.749 | **– / 12.430** | – / 9.702 |

Com 10.000 sessões (rodada 2):

| Servidor | p99 | CPU do servidor (caso) | RSS de pico do servidor |
|---|---|---|---|
| threads | 7.241 ms | 123,8 s | 100 MB (atendeu ~1.000 simultâneas) |
| fibers | 2.738 ms | 31,6 s | 92 MB |
| prefork_fibers | **439 ms** | **37,2 s** | 317 MB (soma de 4 processos) |
| ractor_fibers | 1.000 ms | 45,1 s | **145 MB** |

### 9.2 Leitura

- **[medido] O servidor de threads não acompanha.** Com 5 mil ou 10 mil
  clientes, ele nunca passou de ~1.000 conexões simultâneas e gastou 3–4×
  mais CPU por sessão.
- **[medido] Fibers num processo** atendem até ~1.000 sessões. Depois disso,
  ficam presas a um núcleo (~3.700 sessões/s).
- **[medido] Prefork + Fibers foi o mais rápido nas duas rodadas:** +7% a
  +32% sobre o híbrido com Ractors, menos CPU por sessão e p99 ~2× menor a
  partir de 5 mil sessões (com 1.000: 136 contra 153 ms).
  - Com 10 mil sessões, o gerador chegou a 3,87 dos seus 4 vCPU, então a
    vazão do prefork pode estar **subestimada**.
- **[medido] Ractors + Fibers usa metade (ou menos) da memória** do
  prefork: 145 contra 317 MB com 10 mil sessões. Tudo roda num processo só,
  com estado compartilhável entre Ractors.
  - O RSS do prefork soma os processos e conta mais de uma vez as páginas
    compartilhadas por copy-on-write; a diferença real é menor.
- **[medido] Do Brasil até o VPS, a rede doméstica perde SYN** quando a
  taxa de conexões novas fica alta por vários segundos.
  - O servidor não registrou nenhum descarte (`ListenOverflows`/`ListenDrops` = 0).
  - Uma rajada de 400 conexões passou sem falhas.
  - O teste a partir de casa mede o caminho de rede, não o servidor.
    **[hipótese]** A causa é proteção contra flood ou limite de sessões no
    roteador ou na operadora.

### 9.3 Conclusão para o Mailractor (I/O de entrada)

- **[recomendação] Modelo padrão: processos (prefork) + Fibers (`async`).**
  Foi o mais rápido e o mais estável, funciona em qualquer versão do Ruby e
  é o modelo consolidado no ecossistema (Falcon, Puma em modo cluster).
- **[recomendação] Ractors + Fibers é uma alternativa viável na 4.1**
  quando memória ou estado compartilhado num processo único pesam mais que
  ~20% de vazão.
  - É o caminho que dá feedback mais útil à linguagem.
  - Depende da correção da regressão em § 8.7 antes de ir para produção.
- **[recomendação] Threads por conexão: não usar.**
- **Falta medir:**
  - gerador numa segunda máquina (sem disputa de CPU) e servidor com 8
    vCPU dedicadas;
  - TLS (STARTTLS), que muda o custo de CPU por sessão;
  - sessões com mensagens maiores;
  - o pipeline completo (recepção → spool → workers).
