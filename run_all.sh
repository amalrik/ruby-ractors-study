#!/usr/bin/env bash
# Roda todas as matrizes da POC em sequência (nunca em paralelo, para
# que um cenário não dispute CPU com outro). Tempo total: ~35 min.
set -euo pipefail
cd "$(dirname "$0")"
bundle install >/dev/null

echo "== CPU-bound (principal) =="
ruby cpu_bound/bin/bench.rb

echo "== I/O-bound (principal: tcp + simulação sleep) =="
ruby io_bound/bin/bench.rb

echo "== Suplementar: Ractors TCP com RUBY_MAX_CPU=256 =="
ruby io_bound/bin/bench.rb --workloads tcp --modes sequential,ractors --seq-reps 1 --env RUBY_MAX_CPU=256

echo "== Suplementar: CPU-bound com YJIT (blocos=512) =="
ruby cpu_bound/bin/bench.rb --yjit --blocks 512

echo "== Reprodução isolada: timeout de I/O em Ractors =="
ruby io_bound/bin/repro_ractor_io_timeout.rb 64 400 2>/dev/null | tee io_bound/results/repro_ractor_io_timeout.txt
RUBY_MAX_CPU=64 ruby io_bound/bin/repro_ractor_io_timeout.rb 64 400 2>/dev/null | tee -a io_bound/results/repro_ractor_io_timeout.txt

echo "== Suplementar: CPU-bound Ractors com RUBY_MAX_CPU=16 (blocos=512) =="
ruby cpu_bound/bin/bench.rb --modes sequential,ractors --blocks 512 --env RUBY_MAX_CPU=16

echo "== Suplementar: Ractors sleep com prefetch 4 =="
ruby io_bound/bin/bench.rb --workloads sleep --modes ractors --workers 128,256 --prefetch 4

echo "== Sessões parecidas com SMTP (100..10000 simultâneas) =="
ruby smtp_sessions/bin/bench.rb --ractors 8 --case-timeout 180
