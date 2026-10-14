# Regressão no Ruby 4.1.0-preview1: segfault ao chamar Exception#detailed_message
# (error_highlight) em 2+ Ractors ao mesmo tempo. Sem gems externas.
#
#   ruby repro.rb        # 4.1.0-preview1: [BUG] Segmentation fault (4/4 com 2 Ractors)
#                        # 4.0.6 / 4.0.7: imprime [:ok, :ok]
#
# Observado em 2026-10-14, Linux x86_64, ruby 4.1.0preview1 (2026-10-11 master 2d08b5f42f).
# Pilha: error_highlight -> RubyVM::AbstractSyntaxTree (<internal:ast>:374)
#        -> vm_ic_update -> rb_current_ractor -> SEGV at 0x30
n = Integer(ARGV[0] || 2)
rs = Array.new(n) do |i|
  Ractor.new(i) do |id|
    500.times do |k|
      begin
        raise ArgumentError, "falha #{id}-#{k}"
      rescue => e
        e.detailed_message(highlight: false)
      end
    end
    :ok
  end
end
p rs.map(&:value)
