## I/O-bound — 20261013-203656

| scenario | delay_ms | ops | mode | workers | válido | erros/timeouts | total mediana s (mín–máx) | startup ms | process mediana s | vazão/s | tarefa p50/p95 ms | CPU util | RSS pico MB | speedup |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| io_sleep_simulation | 10 | 2000 | ractors | 128 | sim | 0/0 | 0.187 (0.186–0.189) | 5.7 | 0.182 | 11017.9 | 10.92 / 12.23 | 0.95 | 22.9 | - |
| io_sleep_simulation | 10 | 2000 | ractors | 256 | sim | 0/0 | 0.147 (0.139–0.170) | 10.6 | 0.136 | 14739.2 | 14.98 / 17.90 | 1.39 | 25.7 | - |
