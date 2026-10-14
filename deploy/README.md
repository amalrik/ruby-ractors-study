# Rodando os benchmarks numa máquina efêmera (Hetzner Cloud)

Objetivo: medir **modelos de servidor** (`smtp_sessions/bin/server_bench.rb`)
com o **servidor no VPS** e o **gerador de carga na sua máquina**, com
latência real de internet. Depois, repetir com o gerador também no VPS, para
concorrências que a rede doméstica não aguenta. Ao terminar, **excluir** o
servidor: desligar não para a cobrança.

Custo de referência (tabela oficial da Hetzner, jun/2026, sem IVA):
**CX53** (16 vCPU compartilhadas, 32 GB) ≈ €0,047/h; **CCX33** (8 vCPU
dedicadas, 32 GB) ≈ €0,22/h. Uma tarde de testes custa centavos a poucos
euros. Confira os preços no painel antes de criar.

## 1. Criar o servidor

No console da Hetzner Cloud:

- **Imagem:** Ubuntu 24.04.
- **Tipo:** CX53 para a primeira rodada. Se o steal (registrado em todo
  resultado) passar de ~2–5%, refaça a rodada final numa **CCX33**
  (CPU dedicada).
- **Localização:** a mais próxima de você em RTT. Do Brasil, a costa leste
  dos EUA costuma ser a mais próxima; meça com `ping` se houver mais de uma
  opção.
- **Rede:** IPv4 pública.
- **Chave SSH:** a sua chave pública.

## 2. Preparar (≈10 min, a maior parte compilando o Ruby 4.1)

```sh
IP=203.0.113.10                                  # IP do servidor
MEU_IP=$(curl -s https://ifconfig.me)            # seu IP público (porta 2525 só para ele)
ssh root@$IP "CLIENT_IP=$MEU_IP bash -s" < deploy/provision.sh
deploy/push.sh bench@$IP
```

`provision.sh` cria o usuário `bench`, ajusta `sysctl` e limites para muitas
conexões e libera a porta 2525 **só para o seu IP** (ufw). Se o seu IP
mudar (internet doméstica), rode de novo a linha do `provision.sh` com o IP
novo.

## 3. Checagem rápida

```sh
# do seu computador para o VPS (servidor remoto, gerador local)
ruby smtp_sessions/bin/server_bench.rb --remote bench@$IP --quick --timeout 30
```

## 4. Rodada principal: gerador local → servidor no VPS

Suba a concorrência aos poucos. **O roteador doméstico (NAT/conntrack) e a
operadora costumam ser o primeiro gargalo**, não o servidor. Pare de subir
quando aparecerem erros ou timeouts em **todos** os motores ao mesmo tempo:
isso indica limite da rede, não do modelo de concorrência.

```sh
ruby smtp_sessions/bin/server_bench.rb --remote bench@$IP --workers 100,250,500,1000 --timeout 30
ruby smtp_sessions/bin/server_bench.rb --remote bench@$IP --workers 2000,4000 --timeout 60
```

- Com ~150 ms de RTT, cada sessão (7 idas e voltas) leva ~1 s ou mais.
  O `--timeout` precisa folga.
- Use cabo em vez de Wi-Fi e não use a rede para outras coisas durante a
  medição.
- Cada resultado registra o RTT medido (`RTT ms`) e o steal do servidor
  (`srv steal %`).
- Os resultados ficam **na sua máquina**, em `smtp_sessions/results/`.

## 5. Rodada de alta concorrência: gerador e servidor no VPS

Elimina a rede doméstica. Cliente e servidor dividem as vCPUs, como no
laptop, mas com 16 vCPU de folga:

```sh
ssh bench@$IP
cd concurency-poc
~/.local/bin/mise exec -- ruby smtp_sessions/bin/server_bench.rb --workers 1000,5000,10000,20000 --client-ractors 8 --server-workers 8
exit
deploy/fetch.sh bench@$IP          # traz para remote_results/<IP>/
```

Opcional, para comparar com o laptop: as matrizes antigas no próprio VPS
(`ruby smtp_sessions/bin/bench.rb`, `ruby cpu_bound/bin/bench.rb --blocks 512`).

## 5b. Duas máquinas: gerador dedicado (recomendado)

Elimina a rede doméstica **e** a disputa de CPU entre cliente e servidor.
Custo extra com uma CX43 (8 vCPU) como gerador: ≈ €0,026/h.

1. Crie as **duas na mesma localização** (servidor: CX53 ou CCX33;
   gerador: CX43) e ligue as duas a uma **rede privada** da Hetzner
   (ex.: 10.0.0.0/24). Anote os IPs privados.
2. Prepare as duas. No servidor, libere a porta para o IP **privado** do
   gerador:

   ```sh
   SRV=203.0.113.10; GEN=203.0.113.11            # IPs públicos (para SSH)
   SRV_PRIV=10.0.0.2; GEN_PRIV=10.0.0.3          # IPs privados
   ssh root@$SRV "CLIENT_IP=$GEN_PRIV bash -s" < deploy/provision.sh
   ssh root@$GEN "bash -s" < deploy/provision.sh
   deploy/push.sh bench@$SRV
   deploy/push.sh bench@$GEN
   ```

3. Entre no gerador **com encaminhamento do agente SSH** (`-A`), para que
   ele consiga comandar o servidor com a sua chave, e rode a matriz
   apontando para o IP privado do servidor:

   ```sh
   ssh -A bench@$GEN
   ssh -o StrictHostKeyChecking=accept-new bench@10.0.0.2 true   # aceita a chave do host uma vez
   cd concurency-poc
   ~/.local/bin/mise exec -- ruby smtp_sessions/bin/server_bench.rb \
     --remote bench@10.0.0.2 --workers 1000,5000,10000,20000 --client-ractors 6
   exit
   deploy/fetch.sh bench@$GEN                     # resultados vêm do gerador
   ```

   `--client-ractors` ≈ vCPUs do gerador menos 1–2. Se o `CPU util` do
   cliente ficar perto do número de vCPUs, o gerador virou gargalo: use um
   gerador maior ou menos concorrência.

## 6. Excluir o(s) servidor(es)

No console da Hetzner: cada servidor → **Delete** (no caso 5b, as duas máquinas e a rede privada). Confira na fatura que não
ficou nada ligado (IPs primários, volumes, snapshots).

## Ajustes na sua máquina (gerador local)

- `ulimit -n` alto o bastante (pelo menos o número de sessões simultâneas +
  margem).
- O cliente espera o servidor fechar a conexão depois do `221`, então o
  TIME_WAIT fica do lado do servidor e as portas locais não se esgotam.
  Mesmo assim, se aparecer `EADDRNOTAVAIL`, aumente
  `net.ipv4.ip_local_port_range`.
