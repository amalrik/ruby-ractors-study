# frozen_string_literal: true

module BenchCommon
  module Stats
    module_function

    # Percentil por interpolação linear (p em 0..100).
    def percentile(values, p)
      return nil if values.nil? || values.empty?

      sorted = values.sort
      rank = (p / 100.0) * (sorted.size - 1)
      lo = rank.floor
      hi = rank.ceil
      return sorted[lo] if lo == hi

      sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo)
    end

    def median(values) = percentile(values, 50)

    def summarize(values)
      vals = values.compact
      return { median: nil, min: nil, max: nil } if vals.empty?

      { median: median(vals), min: vals.min, max: vals.max }
    end
  end
end
