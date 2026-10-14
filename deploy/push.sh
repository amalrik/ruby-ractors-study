#!/usr/bin/env bash
# Envia o projeto ao servidor (sem resultados locais) e instala as gems.
#
#   deploy/push.sh bench@IP [diretório_remoto]
set -euo pipefail
cd "$(dirname "$0")/.."

target="${1:?uso: deploy/push.sh bench@IP [diretório_remoto]}"
dir="${2:-concurency-poc}"

rsync -az --delete \
  --exclude '.git/' --exclude '*/results/*' --exclude 'remote_results/' --exclude 'upstream/*/crash-output.txt' \
  ./ "$target:$dir/"

ssh "$target" "cd $dir && ~/.local/bin/mise trust -q mise.toml && ~/.local/bin/mise exec -- bundle install --quiet && ~/.local/bin/mise exec -- ruby -v"
echo "ok: projeto em $target:$dir"
