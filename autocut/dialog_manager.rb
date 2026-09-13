# autocut/dialog_manager.rb
# Owns the HtmlDialog lifecycle: creates the window, registers JS↔Ruby callbacks,
# serializes data for the JavaScript layer, and delegates to Exporter for CSV output.
#
# Business logic (optimization, settings persistence) is intentionally kept outside
# this module — it is received via the initial_result hash and the recalculate proc.

module AutoCut
  module DialogManager
    DIALOG_FILE = File.join(__dir__, 'dialog', 'index.html')

    # instances      — raw per-instance scan data (for CSV export)
    # aggregated     — grouped definition data (for display and export)
    # initial_result — { cross_results:, order:, lengths:, cut_loss: }
    # scope_label    — human-readable scan scope description
    # recalculate:   — proc(lengths_str, cut_loss, solver_name) → result hash (same shape as initial_result)
    def self.show(instances, aggregated, initial_result, scope_label, recalculate:)
      dialog      = build_dialog
      last_result = initial_result

      dialog.add_action_callback('ready') do |_|
        payload = build_init_payload(instances, aggregated, last_result, scope_label)
        dialog.execute_script("initData(#{JSON.generate(payload)})")
      end

      dialog.add_action_callback('recalculate') do |_, params|
        parts       = params.to_s.split('|')
        next unless parts.size >= 2
        lengths_str = parts[0]
        cut_loss    = parts[1].to_f
        solver_name = parts[2].to_s
        next if Settings.parse_lengths(lengths_str).empty? || cut_loss < 0

        last_result = recalculate.call(lengths_str, cut_loss, solver_name)
        push_updates(dialog, aggregated, last_result)
      end

      dialog.add_action_callback('save_instances_csv') { |_| Exporter.save_instances_csv(instances) }

      dialog.add_action_callback('save_aggregated_csv') do |_|
        r = last_result
        Exporter.save_aggregated_csv(aggregated, r[:cross_results], r[:order], r[:lengths], r[:cut_loss])
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

      def push_updates(dialog, aggregated, result)
        dialog.execute_script("updateAggregated(#{JSON.generate(serialize_agg_rows(aggregated, result[:lengths], result[:cut_loss]))})")
        dialog.execute_script("updateCutPlans(#{JSON.generate(serialize_cross_plans(result[:cross_results]))})")
        dialog.execute_script("updateOrderSummary(#{JSON.generate(serialize_order_rows(result[:order], result[:lengths]))})")
        dialog.execute_script("updateMbVolume(#{JSON.generate(serialize_mb_volume(result[:cross_results]))})")
      end

      def build_init_payload(instances, aggregated, result, scope_label)
        {
          scope:        scope_label,
          totalCount:   instances.size,
          invalidCount: instances.count { |i| !i[:valid] },
          srcLengths:   Settings.source_lengths_str,
          cutLoss:      Settings.cut_loss,
          solverName:   Settings.solver_name,
          bfLimit:      AutoCut::BF_LIMIT,
          toleranceMm:  AutoCut::TOLERANCE_MM,
          instanceRows: serialize_instance_rows(aggregated),
          aggRows:      serialize_agg_rows(aggregated, result[:lengths], result[:cut_loss]),
          crossPlans:   serialize_cross_plans(result[:cross_results]),
          orderRows:    serialize_order_rows(result[:order], result[:lengths]),
          mbVolRows:    serialize_mb_volume(result[:cross_results])
        }
      end

      # --- Serialization helpers ---

      def serialize_instance_rows(aggregated)
        aggregated.map do |g|
          {
            name:     g[:name],
            lengthMm: g[:length_cm] ? (g[:length_cm].to_f * 10).round(1) : 0,
            count:    g[:count],
            invalid:  g[:invalid_count] > 0
          }
        end
      end

      def serialize_agg_rows(aggregated, lengths, cut_loss)
        max_len = lengths.empty? ? 0 : lengths.max
        aggregated.map do |g|
          unfit = max_len > 0 && g[:length_cm].to_f > max_len - cut_loss + Optimizer::FLOAT_EPS
          {
            name:    g[:name],
            cross:   g[:cross],
            length:  g[:length_cm],
            count:   g[:count],
            invalid: g[:invalid_count] > 0,
            unfit:   unfit
          }
        end
      end

      def serialize_cross_plans(cross_results)
        cross_results.sort.map do |cross, result|
          {
            cross:      cross,
            unfitCount: result[:unfit_count],
            bins:       result[:bins].map { |b| { src: b[:source_len], cuts: b[:cuts], rest: b[:rest] } }
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

      def serialize_mb_volume(cross_results)
        Aggregator.ordered_linear_metres(cross_results).sort.map do |cross, lm|
          { cross: cross, lm: lm.round(3), m3: Aggregator.volume_m3(cross, lm.round(3)) }
        end
      end
    end
  end
end
