# common — biblioteca compartilhada

Carregada por `require_relative "../../common/lib/bench_common"`.

| Arquivo | Papel |
|---|---|
| `lib/bench_common/pools.rb` | `Sequential`, `ThreadPool` (fila compartilhada, pull) e `RactorPool` (despacho pelo Ractor principal + `Ractor::Port` para respostas). Mesmo contrato: `run(tasks, handler:, ctx:, workers:)` → `RunResult` com `startup_s`, `process_s`, `shutdown_s`, resultados, latências por tarefa e erros. |
| `lib/bench_common/case_runner.rb` | Roda um caso: 1 aquecimento + N repetições, recriando o pool a cada repetição. Emite uma linha JSON por repetição. |
| `lib/bench_common/matrix.rb` | Orquestra a matriz: cada caso num subprocesso Ruby novo; grava `raw.jsonl`, `raw.csv`, `summary.csv`, `summary.md`, `environment.json`. |
| `lib/bench_common/environment.rb` | SO, kernel, CPU, núcleos, memória, governor, versão/API de Ruby, limites de rede. |
| `lib/bench_common/proc_metrics.rb` | RSS atual/pico (`/proc`) e CPU do processo (`Process.times`). |
| `lib/bench_common/stats.rb` | Mediana e percentis. |

## Por que cada caso roda num processo novo

- RSS de pico (`VmHWM`) é por processo; reaproveitar o processo misturaria casos.
- Ractors e threads de um caso não deixam resíduos (GC, threads nativas do
  escalonador M:N) para o próximo.

## Handlers

Um handler é um `Module` com `self.call(payload, ctx)`. Modules são
*shareable*, então podem ser passados para Ractors. `ctx` é convertido com
`Ractor.make_shareable`; `payload` precisa ser frozen.
