# autocut/exporter.rb
# Saves scan results to CSV files (semicolon-separated, UTF-8 BOM for Excel compatibility).

module AutoCut
  module Exporter
    def self.save_instances_csv(instances)
      path = UI.savepanel('Save as CSV', Dir.home, 'components_instances.csv')
      return unless path
      path += '.csv' unless path.downcase.end_with?('.csv')
      write_file(path) do |f|
        f.puts %w[Name Length_mm Width_mm Height_mm Depth_mm Rot_X Rot_Y Rot_Z Valid].join(';')
        instances.each do |i|
          f.puts [
            i[:name], i[:length_mm],
            i[:dim_w], i[:dim_h], i[:dim_d],
            i[:rot_x], i[:rot_y], i[:rot_z],
            i[:valid] ? 'YES' : 'NO'
          ].join(';')
        end
      end
    end

    def self.save_aggregated_csv(optimized_groups, order, lengths, cut_loss_val)
      path = UI.savepanel('Save as CSV', Dir.home, 'components_aggregated.csv')
      return unless path
      path += '.csv' unless path.downcase.end_with?('.csv')
      write_file(path) do |f|
        f.puts "# Available stock lengths: #{lengths.join(', ')} cm | Kerf loss: #{cut_loss_val} cm"
        f.puts ''

        f.puts '## DETAILS'
        f.puts %w[Name Cross_section Length_cm Qty Invalid Cut_plan].join(';')
        optimized_groups.each do |g|
          plan = g[:bins].map { |b|
            "#{b[:source_len].to_i}cm(#{b[:cuts].map { |c| c.to_i }.join('+')})"
          }.join(', ')
          f.puts [g[:name], g[:cross], g[:length_cm], g[:count], g[:invalid_count], plan].join(';')
        end

        f.puts ''
        f.puts '## ORDER'
        f.puts %w[Cross_section Stock_length_cm Qty Total_lm].join(';')
        order.keys.sort.each do |cross|
          lengths.each do |sl|
            cnt = order[cross][sl]
            next unless cnt && cnt > 0
            f.puts [cross, sl.to_i, cnt, (cnt * sl / 100.0).round(2)].join(';')
          end
        end

        lm_by_cross = Aggregator.linear_metres(optimized_groups)

        f.puts ''
        f.puts '## LINEAR_METRES'
        f.puts %w[Cross_section Total_lm].join(';')
        lm_by_cross.keys.sort.each { |c| f.puts [c, lm_by_cross[c].round(3)].join(';') }

        f.puts ''
        f.puts '## VOLUME'
        f.puts %w[Cross_section Volume_m3].join(';')
        lm_by_cross.keys.sort.each do |cross|
          f.puts [cross, Aggregator.volume_m3(cross, lm_by_cross[cross].round(3))].join(';')
        end
      end
    end

    class << self
      private

      def write_file(path)
        File.open(path, 'w:UTF-8') do |f|
          f.write("\xEF\xBB\xBF")
          yield f
        end
        UI.messagebox("Saved: #{path}")
      rescue => e
        UI.messagebox("Write error: #{e.message}")
      end
    end
  end
end
