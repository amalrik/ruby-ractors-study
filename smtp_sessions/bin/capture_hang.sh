#!/usr/bin/env bash
# Tenta reproduzir o travamento do modo `ractors` puro nas sessões e, quando
# ele ocorre, captura o backtrace em C de todas as threads nativas com gdb.
#
#   smtp_sessions/bin/capture_hang.sh [tentativas] [segundos_até_considerar_travado] [prefork_fibers|prefork_threads]
#
# O Ruby é iniciado SOB o gdb (necessário com kernel.yama.ptrace_scope=1).
# Saída: smtp_sessions/results/hang-<timestamp>/
set -uo pipefail
cd "$(dirname "$0")/../.."

attempts=${1:-10}
limit=${2:-30}
engine=${3:-prefork_fibers}
out="smtp_sessions/results/hang-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"

ruby smtp_sessions/bin/session_server.rb --procs 4 --delay-ms 10 --engine "$engine" > "$out/server_port.txt" 2> "$out/server.log" &
server=$!
trap 'kill -TERM $server 2>/dev/null; wait $server 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -q PORT "$out/server_port.txt" 2>/dev/null && break; sleep 0.1; done
port=$(awk '{print $2}' "$out/server_port.txt")

{
  echo "servidor: engine=$engine"
  echo "ruby: $(ruby -v)"
  echo "kernel: $(uname -srvm)"
  echo "gdb: $(gdb --version | head -1)"
  echo "comando: ruby smtp_sessions/bin/run_case.rb --port $port --mode ractors --workers 8 --reps 1"
} > "$out/README.txt"

for i in $(seq 1 "$attempts"); do
  log="$out/attempt-$i.gdb.txt"
  gdb -q -batch -nx \
    -ex "set pagination off" -ex "set print thread-events off" \
    -ex "handle SIGPIPE SIGUSR1 SIGUSR2 SIGVTALRM nostop noprint pass" \
    -ex run -ex "echo === AMOSTRA 1 ===\\n" -ex "info threads" -ex "thread apply all bt" \
    -ex continue -ex "echo === AMOSTRA 2 (5 s depois) ===\\n" -ex "info threads" -ex "thread apply all bt 8" -ex kill \
    --args "$(command -v ruby)" smtp_sessions/bin/run_case.rb --port "$port" --mode ractors --workers 8 --reps 1 \
    > "$log" 2>&1 &
  gdb_pid=$!
  hung=1
  for _ in $(seq 1 $((limit * 10))); do
    kill -0 "$gdb_pid" 2>/dev/null || { hung=0; break; }
    sleep 0.1
  done
  if [ "$hung" -eq 1 ]; then
    ruby_pid=$(pgrep -P "$gdb_pid" -x ruby | head -1)
    echo "tentativa $i: TRAVOU (ruby pid $ruby_pid); capturando backtrace"
    # os dois lados da conexão (cliente e filhos do servidor), com Recv-Q/Send-Q
    ss -tnpo "( sport = :$port or dport = :$port )" 2>/dev/null > "$out/attempt-$i.sockets.txt"
    kill -INT "$ruby_pid"
    sleep 5
    ss -tnpo "( sport = :$port or dport = :$port )" 2>/dev/null > "$out/attempt-$i.sockets-after5s.txt"
    kill -INT "$ruby_pid"
    wait "$gdb_pid"
    echo "  -> $log"
    exit 0
  fi
  wait "$gdb_pid"
  echo "tentativa $i: terminou normalmente"
  rm -f "$log"
done
echo "nenhum travamento em $attempts tentativas"
