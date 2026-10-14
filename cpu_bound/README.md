# cpu_bound — contagem de primos por blocos

Divide `[0, limit)` em blocos contíguos independentes; cada tarefa conta os
primos do seu bloco por divisão por tentativa (ímpares até √n), em Ruby puro.
O total é validado contra um crivo de Eratóstenes (algoritmo independente) e
cada bloco precisa aparecer exatamente uma vez.

Padrão: `limit = 2_000_000` (148.933 primos, ~3 s sequencial sem YJIT nesta
máquina), blocos `32 / 512 / 8192` (≈62.500 / 3.907 / 245 números por bloco),
workers `1, 2, 4, 8, nproc`.

## Comandos

```sh
# matriz completa (sequencial, threads e Ractors; todas as granularidades)
ruby cpu_bound/bin/bench.rb

# variações
ruby cpu_bound/bin/bench.rb --quick
ruby cpu_bound/bin/bench.rb --blocks 512 --workers 1,8,16 --reps 7
ruby cpu_bound/bin/bench.rb --yjit --blocks 512
ruby cpu_bound/bin/bench.rb --prefetch 4      # 4 tarefas em voo por Ractor

# um caso isolado (linhas JSON no stdout)
ruby cpu_bound/bin/run_case.rb --mode sequential
ruby cpu_bound/bin/run_case.rb --mode threads --workers 8 --blocks 512
ruby cpu_bound/bin/run_case.rb --mode ractors --workers 8 --blocks 512
```

Opções de `run_case.rb`: `--mode sequential|threads|ractors`, `--workers N`,
`--limit N`, `--blocks N`, `--warmup N`, `--reps N`, `--prefetch N`, `--expected N`.

Resultados em `cpu_bound/results/<timestamp>/` (ver README raiz).
