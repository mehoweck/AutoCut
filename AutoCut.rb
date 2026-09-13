# AutoCut.rb
# SketchUp extension — component BOM scanner and stock cut optimizer
#
# Entry point: defines shared constants, loads sub-modules, registers the menu item.

require 'sketchup.rb'
require 'json'

module AutoCut
  TOLERANCE_MM = 1.0          # max bbox-vs-name dimension mismatch treated as valid [mm]
  NAME_REGEX   = /^\d+x\d+/   # component names must start with cross-section, e.g. 45x95
  PREF_KEY     = 'AutoCut'
  DIALOG_TITLE = 'StockCut Optimizer & BOM'
  BF_LIMIT     = 12            # max stock pieces per cross-section for brute-force search

  require_relative 'autocut/settings'
  require_relative 'autocut/scanner'
  require_relative 'autocut/aggregator'
  require_relative 'autocut/optimizer'
  require_relative 'autocut/exporter'
  require_relative 'autocut/dialog_manager'

  def self.run
    model                   = Sketchup.active_model
    scope_label, entities   = Scanner.scan_scope(model)
    instances               = Scanner.collect(entities)

    if instances.empty?
      UI.messagebox('No components found matching the naming pattern (e.g. 45x95_joist).')
      return
    end

    aggregated     = Aggregator.aggregate(instances)
    initial_result = compute_optimization(aggregated)

    recalculate = ->(lengths_str, cut_loss_val, solver_name) {
      Settings.save(lengths_str, cut_loss_val, solver_name)
      lengths       = Settings.parse_lengths(lengths_str)
      lengths       = [200.0] if lengths.empty?
      cross_results = Optimizer.optimize_by_cross(aggregated, lengths, cut_loss_val,
                        solver: Optimizer.solver_for(solver_name))
      {
        cross_results: cross_results,
        order:         Optimizer.build_order(cross_results),
        lengths:       lengths,
        cut_loss:      cut_loss_val
      }
    }

    DialogManager.show(instances, aggregated, initial_result, scope_label, recalculate: recalculate)
  end

  def self.compute_optimization(aggregated)
    lengths       = Settings.parse_lengths(Settings.source_lengths_str)
    lengths       = [200.0] if lengths.empty?
    cross_results = Optimizer.optimize_by_cross(aggregated, lengths, Settings.cut_loss,
                      solver: Optimizer.solver_for(Settings.solver_name))
    {
      cross_results: cross_results,
      order:         Optimizer.build_order(cross_results),
      lengths:       lengths,
      cut_loss:      Settings.cut_loss
    }
  end

  unless file_loaded?(__FILE__)
    UI.menu('Extensions').add_item('AutoCut & BOM') { AutoCut.run }
    file_loaded(__FILE__)
  end
end
