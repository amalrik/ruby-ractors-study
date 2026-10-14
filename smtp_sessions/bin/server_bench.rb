#!/usr/bin/env ruby
# frozen_string_literal: true

# Compara MODELOS DE SERVIDOR (o sistema sob teste) com um gerador de carga
# fixo. Para cada motor x nível de concorrência: sobe o servidor (local ou
# remoto via SSH), mede o RTT de conexão, roda o cliente num subprocesso
# novo, encerra o servidor e anexa as estatísticas dele (CPU, RSS de pico,
# steal, sessões por worker).
#
#   # tudo local (loopback)
#   ruby smtp_sessions/bin/server_bench.rb --quick
#
#   # servidor num VPS, gerador nesta máquina (ver deploy/README.md)
#   ruby smtp_sessions/bin/server_bench.rb --remote bench@203.0.113.10 --workers 100,500,1000,2000
#
# O gerador padrão é o cliente `ractor_fibers` (Ractors + Fibers), o mais
# eficiente nas medições anteriores em Ruby 4.1 (report/REPORT.md § 8).

require "etc"
require "json"
require "optparse"
require "shellwords"
require "socket"
require "tmpdir"
require_relative "../../common/lib/bench_common"

ROOT = File.expand_path("..", __dir__)

opts = {
  engines: %w[threads fibers prefork_fibers ractor_fibers],
  server_workers: nil, # padrão: núcleos da máquina do servidor
  workers: [100, 1000, 5000],
  client_mode: "ractor_fibers", client_ractors: [Etc.nprocessors / 2, 1].max,
  delay_ms: 10, body_bytes: 4096, timeout_s: 15.0,
  warmup: 1, reps: 3, case_timeout: 600, rtt_probes: 20,
  remote: nil, remote_dir: "concurency-poc", remote_mise: "~/.local/bin/mise", host: nil, port: 2525
}
OptionParser.new do |o|
  o.on("--quick") { opts.merge!(workers: [100, 1000], reps: 1) }
  o.on("--engines LIST", Array, "motores do servidor") { |v| opts[:engines] = v }
  o.on("--server-workers N", Integer, "processos/Ractors dos motores prefork_*/ractor_*") { |v| opts[:server_workers] = v }
  o.on("--workers LIST", Array, "sessões simultâneas") { |v| opts[:workers] = v.map(&:to_i) }
  o.on("--client-mode MODE", BenchCommon::Pools::MODES) { |v| opts[:client_mode] = v }
  o.on("--client-ractors N", Integer) { |v| opts[:client_ractors] = v }
  o.on("--delay-ms N", Integer) { |v| opts[:delay_ms] = v }
  o.on("--body-bytes N", Integer) { |v| opts[:body_bytes] = v }
  o.on("--timeout S", Float, "timeout de leitura do cliente (aumente com RTT alto)") { |v| opts[:timeout_s] = v }
  o.on("--reps N", Integer) { |v| opts[:reps] = v }
  o.on("--warmup N", Integer) { |v| opts[:warmup] = v }
  o.on("--case-timeout S", Integer) { |v| opts[:case_timeout] = v }
  o.on("--remote USER@HOST", "sobe o servidor via SSH nesse host") { |v| opts[:remote] = v }
  o.on("--remote-dir DIR", "diretório do projeto no host remoto (relativo ao HOME)") { |v| opts[:remote_dir] = v }
  o.on("--remote-mise PATH", "caminho do mise no host remoto") { |v| opts[:remote_mise] = v }
  o.on("--host HOST", "endereço que o cliente usa (padrão: o host de --remote)") { |v| opts[:host] = v }
  o.on("--port N", Integer, "porta fixa do servidor") { |v| opts[:port] = v }
end.parse!

# Sobe/derruba o servidor localmente.
class LocalServer
  def initialize(tmp)
    @tmp = tmp
  end

  def host = "127.0.0.1"

  def cores = Etc.nprocessors

  def start(engine:, workers:, delay_ms:, port:)
    @stats = File.join(@tmp, "srv-#{engine}-#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}.json")
    r, w = IO.pipe
    @pid = Process.spawn(RbConfig.ruby, File.join(ROOT, "bin/session_server.rb"), "--engine", engine,
                         "--workers", workers.to_s, "--delay-ms", delay_ms.to_s, "--port", port.to_s,
                         "--stats-file", @stats, out: w, err: File::NULL)
    w.close
    line = r.gets or raise "servidor local não iniciou"
    r.close
    Integer(line[/PORT (\d+)/, 1])
  end

  def stop
    Process.kill("TERM", @pid)
    Process.wait(@pid)
    JSON.parse(File.read(@stats), symbolize_names: true)
  end
end

# Sobe/derruba o servidor num host remoto via SSH (o projeto precisa ter
# sido enviado com deploy/push.sh).
class RemoteServer
  def initialize(target, dir, mise)
    @target = target
    @dir = dir
    @mise = mise
  end

  def host = @target.split("@").last

  def ssh(cmd)
    out = IO.popen(["ssh", "-o", "BatchMode=yes", @target, cmd], err: %i[child out], &:read)
    raise "ssh falhou (#{$?.exitstatus}): #{out}" unless $?.success?

    out
  end

  def cores = Integer(ssh("nproc").strip)

  def start(engine:, workers:, delay_ms:, port:)
    tag = "srv-#{engine}-#{Time.now.strftime('%H%M%S%L')}"
    @stats = "/tmp/#{tag}.json"
    @out = "/tmp/#{tag}.out"
    cmd = "cd #{@dir.shellescape} && ulimit -n 1048576 2>/dev/null; " \
          "nohup #{@mise} exec -- ruby smtp_sessions/bin/session_server.rb --engine #{engine} " \
          "--workers #{workers} --delay-ms #{delay_ms} --host 0.0.0.0 --port #{port} " \
          "--stats-file #{@stats} > #{@out} 2>&1 < /dev/null & echo $!"
    @pid = Integer(ssh(cmd).strip)
    100.times do
      text = ssh("cat #{@out} 2>/dev/null || true")
      return Integer(text[/PORT (\d+)/, 1]) if text =~ /PORT \d+/
      raise "servidor remoto falhou:\n#{text}" unless ssh("kill -0 #{@pid} 2>/dev/null && echo vivo || echo morto").include?("vivo")

      sleep 0.3
    end
    raise "servidor remoto não respondeu PORT"
  end

  def stop
    ssh("kill -TERM #{@pid}; while kill -0 #{@pid} 2>/dev/null; do sleep 0.2; done")
    JSON.parse(ssh("cat #{@stats}"), symbolize_names: true)
  end
end

# Mediana do tempo de conexão TCP (≈ 1 RTT) ao servidor já em pé.
def connect_rtt_ms(host, port, probes)
  times = Array.new(probes) do
    t0 = BenchCommon::Clock.now
    TCPSocket.new(host, port, connect_timeout: 5).close
    (BenchCommon::Clock.now - t0) * 1000
  end
  BenchCommon::Stats.median(times)
end

Dir.mktmpdir("server-bench") do |tmp|
  server = opts[:remote] ? RemoteServer.new(opts[:remote], opts[:remote_dir], opts[:remote_mise]) : LocalServer.new(tmp)
  client_host = opts[:host] || server.host
  server_workers = opts[:server_workers] || server.cores

  matrix = BenchCommon::Matrix.new(
    name: "Modelos de servidor (#{opts[:remote] ? "remoto #{opts[:remote]}" : 'local'}; " \
          "gerador #{opts[:client_mode]}, delay #{opts[:delay_ms]} ms)",
    case_script: File.join(ROOT, "bin/run_case.rb"),
    results_root: File.join(ROOT, "results"),
    case_keys: %i[scenario server_engine workers],
    group_keys: %i[scenario workers],
    case_timeout: opts[:case_timeout]
  )
  matrix.write_environment(benchmark: "smtp_server_models", options: opts.merge(server_workers: server_workers),
                           role: "cliente/gerador de carga")

  opts[:workers].each do |w|
    $stderr.puts "\n# sessões simultâneas=#{w}"
    opts[:engines].each do |engine|
      port = server.start(engine: engine, workers: server_workers, delay_ms: opts[:delay_ms], port: opts[:port])
      rtt = connect_rtt_ms(client_host, port, opts[:rtt_probes])
      argv = %W[--mode #{opts[:client_mode]} --workers #{w} --delay-ms #{opts[:delay_ms]}
                --body-bytes #{opts[:body_bytes]} --timeout #{opts[:timeout_s]} --warmup #{opts[:warmup]}
                --reps #{opts[:reps]} --host #{client_host} --port #{port}]
      argv += %W[--ractors #{opts[:client_ractors]}] if opts[:client_mode] == "ractor_fibers"
      matrix.run_case(argv) do
        s = server.stop
        { server_engine: engine, server_workers: s[:workers], server_cpu_s: s[:cpu_s],
          server_peak_rss_kb: s[:peak_rss_kb], server_steal_pct: s[:steal_pct],
          server_max_concurrent: s[:max_concurrent], server_accepted: s[:sessions], server_errors: s[:errors],
          server_per_worker: s[:per_worker_sessions], rtt_ms: rtt, client_mode: opts[:client_mode],
          server_host_env: s[:host_env] }
      end
    end
  end

  matrix.finish
end
