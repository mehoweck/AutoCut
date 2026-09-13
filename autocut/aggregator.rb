# autocut/aggregator.rb
# Groups raw instance data by component definition name and provides
# volume / linear-metre calculations shared by the dialog and the CSV exporter.

module AutoCut
  module Aggregator
    def self.aggregate(instances)
      groups = {}
      instances.each do |inst|
        key = inst[:name]
        if groups[key]
          groups[key][:count]         += 1
          groups[key][:invalid_count] += 1 unless inst[:valid]
        else
          cross     = (inst[:dim_a] && inst[:dim_b]) ?
                      "#{inst[:dim_a].to_i}x#{inst[:dim_b].to_i}" : 'N/A'
          groups[key] = {
            name:          key,
            cross:         cross,
            length_cm:     inst[:length_mm] ? (inst[:length_mm] / 10.0).round(1) : nil,
            count:         1,
            invalid_count: inst[:valid] ? 0 : 1
          }
        end
      end
      groups.values.sort_by { |g| g[:name] }
    end

    # Total ordered stock [lm] per cross-section, derived from optimizer bin output.
    # Sums the source lengths of all stock pieces that will be ordered.
    def self.ordered_linear_metres(cross_results)
      cross_results.each_with_object({}) do |(cross, result), totals|
        ordered_cm = result[:bins].sum { |b| b[:source_len] }
        totals[cross] = ordered_cm / 100.0
      end
    end

    # Volume [m³] for a given cross-section string (e.g. "45x95") and total length in lm.
    def self.volume_m3(cross_str, length_lm)
      m = cross_str.match(/^(\d+)x(\d+)$/)
      return 0.0 unless m
      (length_lm * m[1].to_f / 1000.0 * m[2].to_f / 1000.0).round(6)
    end
  end
end
