# frozen_string_literal: true

module BenchCommon
  # Métricas do processo atual. RSS vem de /proc (somente Linux);
  # em outros sistemas os campos ficam nil e são reportados como "não medido".
  module ProcMetrics
    module_function

    def status_kb(field)
      line = File.foreach("/proc/self/status").find { |l| l.start_with?("#{field}:") }
      line && line.split[1].to_i
    rescue Errno::ENOENT
      nil
    end

    def rss_kb = status_kb("VmRSS")
    def peak_rss_kb = status_kb("VmHWM")

    # Ticks de CPU da MÁQUINA inteira (/proc/stat): [steal, total].
    # "steal" é o tempo que o hipervisor deu a outras VMs; em VPS isso
    # distorce benchmarks e precisa ser registrado.
    def system_cpu_ticks
      fields = File.foreach("/proc/stat").first.split.drop(1).map(&:to_i)
      [fields[7] || 0, fields.sum]
    rescue StandardError
      nil
    end

    def steal_pct_between(before, after)
      return nil unless before && after

      total = after[1] - before[1]
      total.positive? ? 100.0 * (after[0] - before[0]) / total : nil
    end

    # CPU (user + system) de todas as threads/Ractors do processo.
    def cpu_seconds
      t = Process.times
      t.utime + t.stime
    end
  end
end
