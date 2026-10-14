#!/usr/bin/env bash
# Traz os resultados gerados NO servidor (quando o gerador também rodou lá)
# para remote_results/<host>/. Rode antes de excluir a máquina.
#
#   deploy/fetch.sh bench@IP [diretório_remoto]
set -euo pipefail
cd "$(dirname "$0")/.."

target="${1:?uso: deploy/fetch.sh bench@IP [diretório_remoto]}"
dir="${2:-concurency-poc}"
host="${target#*@}"
dest="remote_results/$host"
mkdir -p "$dest"

for project in cpu_bound io_bound smtp_sessions; do
  rsync -az "$target:$dir/$project/results/" "$dest/$project/" 2>/dev/null || true
done
ssh "$target" "nproc; lscpu | grep -E 'Model name|Thread|Core|Socket'; systemd-detect-virt; uname -srvm" > "$dest/machine.txt"
echo "resultados em $dest"
