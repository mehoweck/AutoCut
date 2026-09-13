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

    def self.save_aggregated_csv(aggregated, cross_results, order, lengths, cut_loss_val)
      path = UI.savepanel('Save as CSV', Dir.home, 'components_aggregated.csv')
      return unless path
      path += '.csv' unless path.downcase.end_with?('.csv')
      write_file(path) do |f|
        f.puts "# Available stock lengths: #{lengths.join(', ')} cm | Kerf loss: #{cut_loss_val} cm"
        f.puts ''

        f.puts '## DETAILS'
        f.puts %w[Name Cross_section Length_cm Qty Invalid].join(';')
        aggregated.each do |g|
          f.puts [g[:name], g[:cross], g[:length_cm], g[:count], g[:invalid_count]].join(';')
        end

        f.puts ''
        f.puts '## CUT_PLANS'
        f.puts %w[Cross_section Board Stock_cm Cuts_cm Rest_cm].join(';')
        cross_results.sort.each do |cross, result|
          result[:bins].each_with_index do |bin, i|
            cuts_str = bin[:cuts].map { |c| c.round(1) }.join(' + ')
            f.puts [cross, i + 1, bin[:source_len].to_i, cuts_str, bin[:rest].round(1)].join(';')
          end
          if result[:unfit_count] > 0
            f.puts [cross, '!', '—', "#{result[:unfit_count]} piece(s) too long for available stock", '—'].join(';')
          end
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

        lm_by_cross = Aggregator.ordered_linear_metres(cross_results)

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
