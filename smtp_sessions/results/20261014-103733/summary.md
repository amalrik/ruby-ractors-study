## Modelos de servidor (local; gerador ractor_fibers, delay 10 ms) — 20261014-103733

| scenario | server_engine | workers | válido | erros/timeouts | total mediana s (mín–máx) | startup ms | process mediana s | vazão/s | tarefa p50/p95/p99 ms | CPU util | RSS pico MB | speedup | srv conc. máx | srv CPU s (caso) | srv RSS pico MB | RTT ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| smtp_like_sessions | threads | 100 | sim | 0/0 | 0.572 (0.572–0.572) | 0.4 | 0.571 | 525.3 | 173.69 / 222.18 / 274.70 | 0.89 | 36.8 | - | 106 | 1.8 | 36.6 | 0.12 |
| smtp_like_sessions | fibers | 100 | sim | 0/0 | 0.418 (0.418–0.418) | 0.4 | 0.417 | 719.1 | 127.44 / 153.78 / 155.27 | 0.79 | 36.7 | - | 100 | 1.1 | 38.6 | 0.09 |
| smtp_like_sessions | prefork_fibers | 100 | sim | 0/0 | 0.381 (0.381–0.381) | 0.3 | 0.380 | 789.0 | 115.71 / 134.58 / 138.36 | 0.85 | 36.8 | - | 165 | 1.5 | 143.4 | 0.10 |
| smtp_like_sessions | ractor_fibers | 100 | sim | 0/0 | 0.373 (0.373–0.373) | 0.4 | 0.373 | 804.2 | 115.23 / 121.65 / 125.25 | 0.95 | 36.8 | - | 123 | 1.7 | 36.1 | 0.19 |
| smtp_like_sessions | threads | 1000 | sim | 0/0 | 4.332 (4.332–4.332) | 0.5 | 4.331 | 692.6 | 1406.07 / 1535.31 / 1564.07 | 1.02 | 63.7 | - | 195 | 11.0 | 43.6 | 0.06 |
| smtp_like_sessions | fibers | 1000 | sim | 0/0 | 1.198 (1.198–1.198) | 0.2 | 1.198 | 2504.7 | 355.30 / 428.12 / 435.25 | 1.21 | 63.8 | - | 705 | 3.2 | 58.1 | 0.21 |
| smtp_like_sessions | prefork_fibers | 1000 | sim | 0/0 | 1.042 (1.042–1.042) | 0.4 | 1.041 | 2880.7 | 284.14 / 356.34 / 379.13 | 2.83 | 64.0 | - | 1018 | 6.9 | 181.4 | 0.17 |
| smtp_like_sessions | ractor_fibers | 1000 | sim | 0/0 | 1.023 (1.023–1.023) | 0.3 | 1.022 | 2934.5 | 252.65 / 461.85 / 553.36 | 2.54 | 63.7 | - | 946 | 6.5 | 61.0 | 0.07 |
