# autocut/dialog_manager.rb
# Owns the HtmlDialog lifecycle: creates the window, registers JS↔Ruby callbacks,
# computes the initial payload, and serializes data for the JavaScript layer.

module AutoCut
  module DialogManager
    DIALOG_FILE = File.join(__dir__, 'dialog', 'index.html')

    def self.show(instances, aggregated, scope_label)
      lengths   = Settings.parse_lengths(Settings.source_lengths_str)
      lengths   = [200.0] if lengths.empty?
      optimized = Optimizer.optimize_all(aggregated, lengths, Settings.cut_loss, Settings.use_brute_force)
      order     = Optimizer.build_order(optimized)

      dialog = build_dialog
      setup_callbacks(dialog, instances, aggregated)

      # Send initial data once the dialog DOM signals it is ready.
      dialog.add_action_callback('ready') do |_|
        payload = build_init_payload(instances, optimized, order, lengths, scope_label)
        dialog.execute_script("initData(#{JSON.generate(payload)})")
      end

      dialog.set_file(DIALOG_FILE)
      dialog.show
    end

    class << self
      private

      def build_dialog
        UI::HtmlDialog.new(
          dialog_title:    AutoCut::DIALOG_TITLE,
          preferences_key: AutoCut::PREF_KEY,
          scrollable:      true,
          resizable:       true,
          width:           900,
          height:          700,
          left:            150,
          top:             100,
          min_width:       700,
          min_height:      450,
          max_width:       1400,
          max_height:      1000,
          style:           UI::HtmlDialog::STYLE_DIALOG
        )
      end

      def setup_callbacks(dialog, instances, aggregated)
        dialog.add_action_callback('recalculate') do |_, params|
          # params format: "200,300|0.4|bf"  or  "200,300|0.4|greedy"
          parts = params.to_s.split('|')
          next unless parts.size >= 2
          lengths_str = parts[0]
          cut_loss    = parts[1].to_f
          use_bf      = parts[2].to_s == 'bf'
          lengths     = Settings.parse_lengths(lengths_str)
          next if lengths.empty? || cut_loss < 0
          Settings.save(lengths_str, cut_loss, use_bf)

          optimized = Optimizer.optimize_all(aggregated, lengths, cut_loss, use_bf)
          order     = Optimizer.build_order(optimized)
          dialog.execute_script("updateAggregated(#{JSON.generate(serialize_agg_rows(optimized))})")
          dialog.execute_script("updateOrderSummary(#{JSON.generate(serialize_order_rows(order, lengths))})")
          dialog.execute_script("updateMbVolume(#{JSON.generate(serialize_mb_volume(optimized))})")
        end

        dialog.add_action_callback('save_instances_csv') do |_|
          Exporter.save_instances_csv(instances)
        end

        dialog.add_action_callback('save_aggregated_csv') do |_|
          lengths   = Settings.parse_lengths(Settings.source_lengths_str)
          lengths   = [200.0] if lengths.empty?
          optimized = Optimizer.optimize_all(aggregated, lengths, Settings.cut_loss, Settings.use_brute_force)
          order     = Optimizer.build_order(optimized)
          Exporter.save_aggregated_csv(optimized, order, lengths, Settings.cut_loss)
        end
      end

      def build_init_payload(instances, optimized, order, lengths, scope_label)
        {
          scope:        scope_label,
          totalCount:   instances.size,
          invalidCount: instances.count { |i| !i[:valid] },
          srcLengths:   Settings.source_lengths_str,
          cutLoss:      Settings.cut_loss,
          useBf:        Settings.use_brute_force,
          bfLimit:      AutoCut::BF_LIMIT,
          toleranceMm:  AutoCut::TOLERANCE_MM,
          instanceRows: serialize_instance_rows(optimized),
          aggRows:      serialize_agg_rows(optimized),
          orderRows:    serialize_order_rows(order, lengths),
          mbVolRows:    serialize_mb_volume(optimized)
        }
      end

      # --- Serialization helpers ---

      def serialize_instance_rows(optimized)
        optimized.map do |g|
          {
            name:      g[:name],
            lengthMm:  g[:length_cm] ? (g[:length_cm].to_f * 10).round(1) : 0,
            count:     g[:count],
            invalid:   g[:invalid_count] > 0
          }
        end
      end

      def serialize_agg_rows(optimized)
        optimized.map do |g|
          {
            name:    g[:name],
            cross:   g[:cross],
            length:  g[:length_cm],
            count:   g[:count],
            invalid: g[:invalid_count] > 0,
            unfit:   g[:unfit_count].to_i > 0,
            bins:    g[:bins].map { |b| { src: b[:source_len], cuts: b[:cuts], rest: b[:rest] } }
          }
        end
      end

      def serialize_order_rows(order, lengths)
        rows = []
        order.keys.sort.each do |cross|
          lengths.each do |sl|
            cnt = order[cross][sl]
            next unless cnt && cnt > 0
            rows << { cross: cross, sl: sl, count: cnt, lm: (cnt * sl / 100.0).round(2) }
          end
        end
        rows
      end

      def serialize_mb_volume(optimized)
        Aggregator.linear_metres(optimized).sort.map do |cross, lm|
          { cross: cross, lm: lm.round(3), m3: Aggregator.volume_m3(cross, lm.round(3)) }
        end
      end
    end
  end
end
