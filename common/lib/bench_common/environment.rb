# frozen_string_literal: true

require "etc"
require "rbconfig"

module BenchCommon
  # Captura o ambiente da máquina para acompanhar os resultados.
  module Environment
    module_function

    def read(path)
      File.read(path).strip
    rescue StandardError
      nil
    end

    def cmd(*argv)
      out = IO.popen(argv, err: File::NULL, &:read)
      $?.success? ? out.strip : nil
    rescue StandardError
      nil
    end

    def cpu_model
      line = File.foreach("/proc/cpuinfo").find { |l| l.start_with?("model name") }
      line&.split(":", 2)&.last&.strip
    rescue StandardError
      nil
    end

    def physical_cores
      pairs = File.read("/proc/cpuinfo").split("\n\n").filter_map do |block|
        phys = block[/^physical id\s*:\s*(\d+)/, 1]
        core = block[/^core id\s*:\s*(\d+)/, 1]
        [phys, core] if core
      end
      pairs.uniq.size.nonzero?
    rescue StandardError
      nil
    end

    def mem_total_kb
      line = File.foreach("/proc/meminfo").find { |l| l.start_with?("MemTotal:") }
      line&.split&.[](1)&.to_i
    rescue StandardError
      nil
    end

    def os_release
      data = read("/etc/os-release") or return nil
      data[/^PRETTY_NAME="?([^"\n]+)"?/, 1]
    end

    def capture(extra = {})
      {
        captured_at: Time.now.utc.iso8601,
        os: os_release,
        kernel: cmd("uname", "-srvm"),
        cpu_model: cpu_model,
        logical_cpus: Etc.nprocessors,
        physical_cores: physical_cores,
        mem_total_kb: mem_total_kb,
        cpu_governor: read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
        cpu_driver: read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver"),
        energy_perf_preference: read("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"),
        loadavg_at_start: read("/proc/loadavg"),
        ruby_description: RUBY_DESCRIPTION,
        ruby_engine: RUBY_ENGINE,
        ruby_version: RUBY_VERSION,
        ruby_bin: RbConfig.ruby,
        ractor_api: {
          port: defined?(Ractor::Port) ? true : false,
          ractor_value: Ractor.method_defined?(:value),
          ractor_join: Ractor.method_defined?(:join),
          legacy_take_yield: Ractor.method_defined?(:take) || Ractor.respond_to?(:yield)
        },
        # "none" = máquina física; sai com código 1 nesse caso, por isso não usa cmd()
        virtualization: (IO.popen(["systemd-detect-virt"], err: File::NULL, &:read).strip rescue "desconhecido"),
        dmi_product: read("/sys/class/dmi/id/product_name"),
        dmi_vendor: read("/sys/class/dmi/id/sys_vendor"),
        ruby_max_cpu_env: ENV["RUBY_MAX_CPU"],
        tcp_max_syn_backlog: read("/proc/sys/net/ipv4/tcp_max_syn_backlog"),
        tcp_tw_reuse: read("/proc/sys/net/ipv4/tcp_tw_reuse"),
        ip_local_port_range: read("/proc/sys/net/ipv4/ip_local_port_range")&.split&.join("-"),
        somaxconn: read("/proc/sys/net/core/somaxconn"),
        nofile_limit: Process.getrlimit(Process::RLIMIT_NOFILE).first
      }.merge(extra)
    end
  end
end

require "time"
