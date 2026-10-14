#!/usr/bin/env bash
# Repete as matrizes principais na Ruby 4.1.0-preview1 (via mise) para
# comparar com a 4.0.6. Rodar sem outras cargas na máquina (~25 min).
set -euo pipefail
cd "$(dirname "$0")"
R=(mise exec ruby@4.1.0-preview1 --)
"${R[@]}" bundle install >/dev/null

echo "== 4.1: sessões SMTP (todos os modos) =="
"${R[@]}" ruby smtp_sessions/bin/bench.rb --ractors 8 --case-timeout 180

echo "== 4.1: I/O TCP + sleep =="
"${R[@]}" ruby io_bound/bin/bench.rb --modes sequential,threads,ractors,fibers,ractor_fibers --ractors 8 --seq-reps 1

echo "== 4.1: CPU (blocos=512) =="
"${R[@]}" ruby cpu_bound/bin/bench.rb --blocks 512
