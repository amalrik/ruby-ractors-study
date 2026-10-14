#!/usr/bin/env bash
# Prepara um servidor Ubuntu 24.04 NOVO e descartável para os benchmarks.
# Roda como root NO SERVIDOR, enviado pela sua máquina:
#
#   ssh root@IP "CLIENT_IP=$(curl -s https://ifconfig.me) bash -s" < deploy/provision.sh
#
# O que faz:
#   - cria o usuário `bench` (com a mesma chave SSH do root);
#   - instala dependências de compilação do Ruby e liburing (seletor io_uring do async);
#   - ajusta sysctl e limites para dezenas de milhares de conexões;
#   - firewall: SSH aberto; porta do benchmark (2525) só para CLIENT_IP;
#   - instala mise e compila Ruby 4.1.0-preview1 para o usuário `bench`.
#
# Não use em servidor que você queira manter: é feito para máquinas efêmeras.
set -euo pipefail

RUBY_VERSION_WANTED="${RUBY_VERSION_WANTED:-4.1.0-preview1}"
BENCH_PORT="${BENCH_PORT:-2525}"
CLIENT_IP="${CLIENT_IP:-}"

if [ "$(id -u)" -ne 0 ]; then echo "rode como root" >&2; exit 1; fi

echo "== pacotes"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential autoconf bison libssl-dev libyaml-dev zlib1g-dev libffi-dev \
  libgmp-dev libreadline-dev liburing-dev git curl rsync ufw >/dev/null

echo "== usuário bench"
if ! id bench >/dev/null 2>&1; then
  useradd -m -s /bin/bash bench
  mkdir -p /home/bench/.ssh
  cp /root/.ssh/authorized_keys /home/bench/.ssh/authorized_keys
  chown -R bench:bench /home/bench/.ssh
  chmod 700 /home/bench/.ssh && chmod 600 /home/bench/.ssh/authorized_keys
fi

echo "== sysctl e limites"
cat > /etc/sysctl.d/99-bench.conf <<'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 2097152
fs.nr_open = 2097152
EOF
sysctl -q --system
cat > /etc/security/limits.d/99-bench.conf <<'EOF'
bench soft nofile 1048576
bench hard nofile 1048576
bench soft nproc  262144
bench hard nproc  262144
EOF

echo "== firewall"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
if [ -n "$CLIENT_IP" ]; then
  ufw allow from "$CLIENT_IP" to any port "$BENCH_PORT" proto tcp >/dev/null
  echo "porta $BENCH_PORT liberada só para $CLIENT_IP"
else
  echo "AVISO: CLIENT_IP vazio; porta $BENCH_PORT fechada (só testes locais no servidor)"
fi
ufw --force enable >/dev/null

echo "== mise + Ruby $RUBY_VERSION_WANTED (compila; leva alguns minutos)"
# O script chega por stdin (bash -s); o subcomando NÃO pode herdar esse
# stdin, senão consome o resto do script e não executa. Por isso: arquivo
# temporário + </dev/null.
cat > /tmp/bench-ruby.sh <<EOS
set -euo pipefail
[ -x ~/.local/bin/mise ] || curl -fsSL https://mise.run | sh
MAKE_OPTS="-j\$(nproc)" ~/.local/bin/mise install ruby@$RUBY_VERSION_WANTED
~/.local/bin/mise exec ruby@$RUBY_VERSION_WANTED -- ruby -v
EOS
chmod 755 /tmp/bench-ruby.sh
sudo -iu bench bash /tmp/bench-ruby.sh </dev/null
rm -f /tmp/bench-ruby.sh

echo "== pronto. Próximo passo, na sua máquina: deploy/push.sh bench@$(hostname -I | awk '{print $1}')"
