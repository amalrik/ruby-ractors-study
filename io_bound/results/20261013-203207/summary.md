## I/O-bound — 20261013-203207

| scenario | delay_ms | ops | mode | workers | válido | erros/timeouts | total mediana s (mín–máx) | startup ms | process mediana s | vazão/s | tarefa p50/p95 ms | CPU util | RSS pico MB | speedup |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| io_sleep_simulation | 10 | 2000 | sequential | 1 | sim | 0/0 | 20.360 (20.356–20.365) | 0.0 | 20.360 | 98.2 | 10.12 / 10.37 | 0.01 | 18.3 | 1.00x |
| io_sleep_simulation | 10 | 2000 | threads | 8 | sim | 0/0 | 2.540 (2.537–2.542) | 0.9 | 2.539 | 787.7 | 10.11 / 10.31 | 0.05 | 19.1 | 8.02x |
| io_sleep_simulation | 10 | 2000 | threads | 32 | sim | 0/0 | 0.644 (0.644–0.646) | 2.4 | 0.641 | 3121.1 | 10.11 / 10.40 | 0.14 | 20.0 | 31.62x |
| io_sleep_simulation | 10 | 2000 | threads | 128 | sim | 0/0 | 0.178 (0.176–0.179) | 9.5 | 0.166 | 12024.3 | 10.13 / 11.08 | 0.40 | 23.2 | 114.59x |
| io_sleep_simulation | 10 | 2000 | threads | 256 | sim | 0/0 | 0.106 (0.103–0.109) | 16.6 | 0.087 | 23098.9 | 10.22 / 12.20 | 0.66 | 31.8 | 191.59x |
| io_sleep_simulation | 10 | 2000 | ractors | 8 | sim | 0/0 | 2.607 (2.604–2.612) | 0.4 | 2.607 | 767.2 | 10.23 / 10.53 | 0.09 | 20.4 | 7.81x |
| io_sleep_simulation | 10 | 2000 | ractors | 32 | sim | 0/0 | 0.771 (0.758–0.779) | 1.3 | 0.769 | 2601.5 | 10.73 / 12.01 | 0.31 | 20.8 | 26.42x |
| io_sleep_simulation | 10 | 2000 | ractors | 128 | sim | 0/0 | 0.239 (0.221–0.244) | 4.7 | 0.234 | 8559.5 | 10.75 / 12.20 | 0.99 | 23.1 | 85.33x |
| io_sleep_simulation | 10 | 2000 | ractors | 256 | sim | 0/0 | 0.206 (0.198–0.220) | 11.4 | 0.195 | 10279.8 | 9.92 / 12.17 | 1.33 | 24.5 | 98.71x |
