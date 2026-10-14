## Sessões parecidas com SMTP (delay 10 ms por resposta, corpo 4096 B) — 20261014-002018

| scenario | mode | ractors | workers | válido | erros/timeouts | total mediana s (mín–máx) | startup ms | process mediana s | vazão/s | tarefa p50/p95/p99 ms | CPU util | RSS pico MB | speedup | srv conc. máx | srv CPU s (caso) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| smtp_like_sessions | fibers |  | 1000 | sim | 0/0 | 0.799 (0.796–0.803) | 7.8 | 0.791 | 3792.6 | 250.64 / 301.49 / 320.09 | 0.74 | 63.9 | - | 1523 | 4.4 |
| smtp_like_sessions | ractor_fibers | 8 | 1000 | sim | 0/0 | 0.423 (0.420–0.446) | 0.3 | 0.423 | 7099.7 | 128.50 / 144.59 / 149.71 | 3.21 | 70.2 | - | 1524 | 4.1 |
| smtp_like_sessions | fibers |  | 5000 | sim | 0/0 | 4.248 (4.143–4.310) | 39.5 | 4.209 | 3564.1 | 1367.37 / 1521.33 / 1730.56 | 0.80 | 191.1 | - | 6321 | 22.8 |
| smtp_like_sessions | ractor_fibers | 8 | 5000 | sim | 0/0 | 1.593 (1.586–1.607) | 0.5 | 1.592 | 9421.5 | 471.51 / 533.11 / 548.93 | 4.54 | 200.5 | - | 2806 | 20.8 |
