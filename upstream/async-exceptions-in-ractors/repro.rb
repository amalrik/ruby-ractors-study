# `async` em vários Ractors com tarefas que terminam em exceção (o async
# registra a falha via gem `console`, que chama detailed_message).
#
#   bundle exec ruby repro.rb   # 4.0.6: trava (5/5); 4.1.0-preview1: segfault (1/5)
#
# Na 4.1 a causa é a regressão em ../ruby-4.1-detailed-message-ractors.
# Na 4.0.6 o travamento não foi diagnosticado.
require "async"
n = Integer(ARGV[0] || 4)
rs = Array.new(n) do |i|
  Ractor.new(i) do |id|
    Sync do |task|
      50.times.map { |k| task.async { raise ArgumentError, "falha #{id}-#{k}" } }.each { |t| t.wait rescue nil }
    end
    :ok
  end
end
p rs.map(&:value)
