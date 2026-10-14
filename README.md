# POC: threads vs. Ractors (Mailractor)

POC local em Ruby (única dependência externa: a gem `async`, para os modos com Fibers), para medir como threads e
Ractors se comportam em cargas **CPU-bound** e **I/O-bound** antes de desenhar o
runtime de jobs do Mailractor. Não há SMTP aqui; o objetivo é aprender custos,
ganhos e limitações de ergonomia.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| [`common/`](common/) | Biblioteca compartilhada: pools (sequencial, threads, Ractors), estatísticas, coleta de ambiente/RSS/CPU, orquestrador da matriz e gravação de CSV/JSON/Markdown. |
| [`cpu_bound/`](cpu_bound/) | Projeto 1: contagem de primos por blocos. |
| [`io_bound/`](io_bound/) | Projeto 2: servidor TCP local com atraso + clientes; inclui simulação com `sleep` e a reprodução de um limite de I/O em Ractors. |
| [`smtp_sessions/`](smtp_sessions/) | Projeto 3: sessões de várias etapas parecidas com SMTP (até 10k simultâneas), servidor prefork + `async`, modos threads/fibers/ractors/híbrido; reprodutores dos bugs de Ractors com sockets. |
| [`deploy/`](deploy/) | Scripts para rodar num servidor efêmero (Hetzner): preparar, enviar o projeto, buscar resultados. |
| [`upstream/`](upstream/) | Reprodutores mínimos de bugs encontrados, para relatar ao Ruby e às gems. |
| [`report/`](report/) | Relatório com ambiente, metodologia, resultados, conclusões e dificuldades de ergonomia. |
| `run_all.sh` | Roda todas as matrizes em sequência (~35 min). |
| `run_ruby41.sh` | Repete as matrizes principais na Ruby 4.1.0-preview1 via `mise` (~25 min). |
| `Gemfile` | `async` (Fibers) e `csv`. |

## Requisitos

- Ruby **4.1** (fixado em `mise.toml`; 4.0.x também roda, mas veja o relatório § 8).
  CRuby. A POC usa a API de Ractors do Ruby 4.0
  (`Ractor::Port`, `Ractor#join`, `Ractor#value`); não funciona em Ruby 3.x,
  onde a API era `Ractor.yield`/`Ractor#take`. Veja no relatório (§ 8) por
  que a versão importa.
- `bundle install` uma vez (gem `async`).
- Linux para RSS (`/proc/self/status`). Em outros sistemas a métrica fica como "n/m".
- Nada de rede externa: o servidor de I/O escuta em `127.0.0.1`.

## Como rodar

```sh
./run_all.sh                       # tudo, gera results/ em cada projeto

ruby cpu_bound/bin/bench.rb --quick  # checagem rápida (~5 s)
ruby io_bound/bin/bench.rb --quick   # checagem rápida (~15 s)
ruby smtp_sessions/bin/bench.rb --quick  # checagem rápida (~15 s)
```

Cada projeto tem um README com os comandos de cada cenário/modo.

Os resultados ficam em `<projeto>/results/<timestamp>/`:
`environment.json`, `raw.jsonl`, `raw.csv` (uma linha por repetição, incluindo
aquecimento), `summary.csv` e `summary.md`. O arquivo `results/LATEST` aponta
para a execução mais recente.

Relatório: [`report/REPORT.md`](report/REPORT.md). Análise do solid-jobs:
[`report/solid-jobs-analysis.md`](report/solid-jobs-analysis.md).
