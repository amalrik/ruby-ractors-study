# Threads vs. Ractors vs. Fibers in Ruby 4.0 / 4.1: a benchmark study

*(Portuguese is the main language of this repository: see [README.md](README.md) and the full report
in [report/REPORT.md](report/REPORT.md). This page is an English summary for Ruby/async maintainers and
anyone arriving from a bug report.)*

This is an educational study, not a product. I am evaluating concurrency models for a small mail
server written in Ruby ("Mailractor") and writing about it on my blog. Along the way I ran into
several Ractor issues in Ruby 4.0.x and 4.1, which are documented here with standalone reproducers.

## What is measured

| Project | Workload | Modes |
|---|---|---|
| [`cpu_bound/`](cpu_bound/) | Counting primes in independent blocks (trial division, pure Ruby) | sequential, threads, Ractors |
| [`io_bound/`](io_bound/) | One TCP request per operation against a local delay server; `sleep` simulation | sequential, threads, Ractors, Fibers (`async`), Ractors+Fibers |
| [`smtp_sessions/`](smtp_sessions/) | Long multi-step SMTP-like sessions (banner, EHLO, MAIL, RCPT, DATA 4 KB, QUIT), up to 10k concurrent | client models **and** server models: threads, fibers, prefork+fibers, Ractors+fibers (`SO_REUSEPORT`) |

Every case runs in a fresh process, with warm-up and repetitions. Raw results (JSONL/CSV) and the
environment of each run are under `*/results/` and `remote_results/`.

## Main findings (details and caveats in the report)

- **CPU-bound:** threads give ~1× (GVL). Ractors give 4.7–5.4× with 8 workers on 8 physical cores.
  Startup and memory costs are negligible.
- **Ractors + socket I/O on Ruby 4.0.6/4.0.7:**
  - **Concurrency cap.** A Ractor that waited in `Ractor.receive` / `Ractor::Port#receive` before
    doing I/O with a timeout (`IO#wait_readable(t)`, `IO#timeout=`) is limited to roughly
    `RUBY_MAX_CPU` concurrent waits.
    Repro: [`io_bound/bin/repro_ractor_receive_first.rb`](io_bound/bin/repro_ractor_receive_first.rb).
    Fixed in 4.1.0-preview1.
  - **Intermittent hangs, where the read timeout never fires, and one `double free or corruption`
    in GC sweep.** These appeared in multi-step socket clients running in Ractors (6/20 runs on
    4.0.6, 4/20 on 4.0.7, 0/40 on 4.1.0-preview1).
    See [`smtp_sessions/bin/repro_ractor_session_hang.rb`](smtp_sessions/bin/repro_ractor_session_hang.rb),
    the gdb captures in `smtp_sessions/results/hang-*`, and
    `smtp_sessions/results/crash/abort-real-15.txt`.
- **SEGV with Ractors + error_highlight on Ruby 4.1 built with GCC 16.** Calling
  `Exception#detailed_message` from 2+ Ractors at the same time segfaults inside
  `Thread::Backtrace::Location#syntax_tree` (`<internal:ast>:374` → `vm_ic_update` →
  `rb_current_ractor`). With one Ractor, `error_highlight` silently drops its snippet.
  Reported as [Bug #22439](https://bugs.ruby-lang.org/issues/22439); see
  [`upstream/ruby-4.1-detailed-message-ractors/`](upstream/ruby-4.1-detailed-message-ractors/).
  - **Update (2026-10-14):** Ruby core found that the crash needs **GCC 16** (my 4.1 builds used
    GCC 16.2.1; the 4.0.x binaries I compared against were prebuilt with GCC 10, so my
    "4.1 regression" label was confounded by the compiler). The ticket was split into
    [#22440](https://bugs.ruby-lang.org/issues/22440): GCC 16 caches the TLS execution-context
    address across an autoload that can resume the thread on another native thread under M:N.
    The fix is [ruby/ruby#19348](https://github.com/ruby/ruby/pull/19348).
    The other part is [#22442](https://bugs.ruby-lang.org/issues/22442): concurrent callers skipped
    error_highlight's lazy load. The fix is [ruby/ruby#19352](https://github.com/ruby/ruby/pull/19352).
    With both patches on master 3d168b1 (same GCC 16), every reproducer here runs clean (10/10)
    and the snippet appears in every Ractor.
- **Server models on a VPS** (Hetzner CPX42, 8 vCPU; 4 for the server, 4 for the load generator;
  Ruby 4.1.0-preview1; 10k concurrent SMTP-like sessions):

  | Server | Sessions/s | p99 | Server RSS |
  |---|---|---|---|
  | threads | ~1,460 | 7.2 s | 100 MB |
  | fibers (1 process) | ~3,750 | 2.7 s | 92 MB |
  | prefork + fibers (4 processes) | ~12,430 | 0.44 s | 317 MB (sum) |
  | Ractors + fibers (4 Ractors, 1 process) | ~9,700 | 1.0 s | 145 MB |

  Ractors + Fibers achieves real parallelism inside one process. Each Ractor runs its own `async`
  reactor and its own `SO_REUSEPORT` listener. It is ~20% behind prefork, with half the memory.

## Running

Requires CRuby 4.0+ (4.1.0-preview1 pinned in `mise.toml`) and `bundle install` (`async`, `csv`).

```sh
ruby cpu_bound/bin/bench.rb --quick
ruby io_bound/bin/bench.rb --quick
ruby smtp_sessions/bin/server_bench.rb --quick
```

Each project has its own README. [`deploy/`](deploy/) contains scripts to run the server benchmarks
on a throwaway cloud VM.
