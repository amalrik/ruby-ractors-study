# Variante sem error_highlight: Thread::Backtrace::Location#syntax_tree
# (API nova na 4.1; NoMethodError na 4.0.x) sobre a localização de uma
# exceção, em 2 Ractors ao mesmo tempo.
#   4.1.0dev (master 2026-10-14, b709bdb3e3): segfault em 1/3 execuções
#   4.1.0-preview1: 0/3 (o repro.rb com detailed_message falha em 100%)
# Mesma pilha: <internal:ast>:374 -> vm_ic_update -> rb_current_ractor
n = Integer(ARGV[0] || 2)
rs = Array.new(n) do
  Ractor.new do
    r = nil
    200.times do
      begin
        nil.upcase
      rescue => e
        r = e.backtrace_locations.first.syntax_tree
      end
    end
    [:ok, r.class]
  rescue Exception => e
    [e.class, e.message[0, 120]]
  end
end
p rs.map(&:value)
