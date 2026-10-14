# frozen_string_literal: true

# Carga CPU-bound: contar primos em blocos independentes de um intervalo.
# Divisão por tentativa (ímpares até sqrt(n)) em Ruby puro: propositalmente
# simples e determinística, sem alocações por número.
module Primes
  module_function

  def prime?(n)
    return n >= 2 if n < 4
    return false if n.even?

    i = 3
    while i * i <= n
      return false if (n % i).zero?

      i += 2
    end
    true
  end

  # Conta primos em [lo, hi).
  def count_range(lo, hi)
    count = 0
    n = lo
    while n < hi
      count += 1 if prime?(n)
      n += 1
    end
    count
  end

  # Divide [0, limit) em `block_count` blocos contíguos.
  # Retorna [[task_id, [lo, hi]], ...] já frozen (shareable).
  def blocks(limit, block_count)
    size = (limit.to_f / block_count).ceil
    Array.new(block_count) do |i|
      lo = i * size
      hi = [lo + size, limit].min
      [i, [lo, hi].freeze].freeze
    end.reject { |_, (lo, hi)| lo >= hi }.freeze
  end

  # Referência independente para validação: crivo de Eratóstenes.
  def sieve_count(limit)
    return 0 if limit < 3

    composite = "\0".b * limit
    composite.setbyte(0, 1)
    composite.setbyte(1, 1)
    i = 2
    while i * i < limit
      if composite.getbyte(i).zero?
        j = i * i
        while j < limit
          composite.setbyte(j, 1)
          j += i
        end
      end
      i += 1
    end
    composite.count("\0")
  end

  # Handler usado pelos pools: payload = [lo, hi].
  module Handler
    def self.call(payload, _ctx) = Primes.count_range(payload[0], payload[1])
  end
end
