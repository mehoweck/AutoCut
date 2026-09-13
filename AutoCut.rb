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

    aggregated = Aggregator.aggregate(instances)
    DialogManager.show(instances, aggregated, scope_label)
  end

  unless file_loaded?(__FILE__)
    UI.menu('Extensions').add_item('AutoCut & BOM') { AutoCut.run }
    file_loaded(__FILE__)
  end
end
