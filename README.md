# AutoCut — StockCut Optimizer & BOM

A SketchUp extension that scans a model for lumber components, builds a bill of materials, and computes an optimised cut plan for ordering stock lengths.

## Features

- Scans the active model or a selected group (auto-fallback)
- Per-instance view: dimensions, rotation, name-vs-bbox validation
- Aggregated view: bin-packing optimisation per cross-section
- Configurable available stock lengths (comma-separated list, e.g. `100,150,200,300`)
- Two optimisation algorithms: **Greedy FFD** (fast) and **Brute Force** (optimal, up to 12 bins)
- Order summary: pieces and linear metres per cross-section and stock length
- Volume [m³] per cross-section
- CSV export (semicolon-separated, UTF-8 BOM for Excel compatibility)
- Sortable columns (click header)
- Length unit switcher: mm / cm / m
- Settings persisted between sessions via `Sketchup.write_default`

## Component naming convention

Component definition names must start with the cross-section in the format `<width>x<height>`, e.g.:

```
45x95_joist
45x145_rim_board
18x18
```

The extension extracts the two cross-section dimensions from the name and identifies the longest remaining bounding-box axis as the element length.
A row is marked invalid (red) when the bbox dimensions do not match the name within a 1 mm tolerance.

---

## File structure

```
AutoCut.rb                     # Entry point: constants, requires, menu registration
autocut/
  settings.rb                  # Persistent preferences (read/write_default, parse_lengths)
  scanner.rb                   # Model traversal → raw instance data
  aggregator.rb                # Instance grouping, linear metres, volume
  optimizer.rb                 # Bin-packing: Greedy FFD + Brute Force (BFSolver class)
  exporter.rb                  # CSV export (instances + aggregated)
  dialog_manager.rb            # HtmlDialog lifecycle, JS↔Ruby callbacks, JSON serialisation
  dialog/
    index.html                 # Dialog HTML structure (static, no inline scripts)
    style.css                  # All styles
    app.js                     # All JavaScript: rendering, sorting, unit conversion
```

### Module responsibilities

| File | Module | Responsibility |
|------|--------|----------------|
| `AutoCut.rb` | `AutoCut` | Constants, `run` entry point, menu item |
| `settings.rb` | `AutoCut::Settings` | Read/write SketchUp preferences, parse length strings |
| `scanner.rb` | `AutoCut::Scanner` | Recursively collect `ComponentInstance` entities, extract bbox/rotation data |
| `aggregator.rb` | `AutoCut::Aggregator` | Group instances by definition name; compute linear metres and volume |
| `optimizer.rb` | `AutoCut::Optimizer` | 1-D bin-packing; `BFSolver` inner class for brute-force state |
| `exporter.rb` | `AutoCut::Exporter` | Write CSV files with UTF-8 BOM |
| `dialog_manager.rb` | `AutoCut::DialogManager` | Create dialog, register callbacks, serialise data to JSON |

---

## Data flow

```
AutoCut.run
  │
  ├─ Scanner.scan_scope(model)
  │     Returns: [scope_label, entities]
  │
  ├─ Scanner.collect(entities)
  │     Recursively visits ComponentInstances matching /^\d+x\d+/
  │     Returns: instances[]  (one hash per instance with :name, :dim_a/b, :dims_mm,
  │                             :length_mm, :rot_x/y/z, :valid)
  │
  ├─ Aggregator.aggregate(instances)
  │     Groups by definition name, counts occurrences, flags invalids
  │     Returns: aggregated[]  (:name, :cross, :length_cm, :count, :invalid_count)
  │
  └─ DialogManager.show(instances, aggregated, scope_label)
        │
        ├─ Settings.parse_lengths / Settings.cut_loss / Settings.use_brute_force
        │
        ├─ Optimizer.optimize_all(aggregated, lengths, cut_loss, use_bf)
        │     For each group: Optimizer.optimize(pieces, lengths, cut_loss, use_bf)
        │       → greedy_ffd (Greedy FFD)
        │         or BFSolver#solve (recursive DFS with pruning + symmetry dedup)
        │     Returns: optimized[]  (aggregated + :bins, :unfit_count)
        │
        ├─ Optimizer.build_order(optimized)
        │     Returns: { cross_section => { stock_length => piece_count } }
        │
        ├─ DialogManager serialises all data to JSON
        │
        ├─ dialog.set_file("autocut/dialog/index.html")
        ├─ dialog.show
        └─ on JS "ready" callback → dialog.execute_script("initData({...})")
                                         │
                                         └─ app.js populates all tables

On "Recalculate" (user changes stock lengths / kerf / algorithm):
  JS → sketchup.recalculate("lengths|kerf|algo")
  Ruby callback → Settings.save + Optimizer.optimize_all + build_order
               → execute_script updateAggregated / updateOrderSummary / updateMbVolume

On "Save CSV":
  JS → sketchup.save_instances_csv()  or  sketchup.save_aggregated_csv()
  Ruby callback → Exporter.save_instances_csv / save_aggregated_csv
```

---

## Optimisation algorithms

### Greedy FFD (default)

First-Fit Decreasing heuristic. Pieces are sorted largest-first and placed into
the tightest existing bin that still fits. A new bin is opened only when no
existing bin has enough remaining space. O(n²) over bins — fast enough for
typical BOM sizes.

### Brute Force (optional)

Exhaustive recursive search with two pruning strategies:

1. **Cost pruning** — branches whose partial cost already exceeds the best
   known solution are abandoned.
2. **Symmetry deduplication** — within a single recursion level, bins with
   identical remaining space are treated as equivalent and only one is explored.

Automatically falls back to the Greedy result if brute force finds nothing
better. Capped at `BF_LIMIT = 12` bins per cross-section to keep runtime
acceptable.

The search state (`@best`, `@best_cost`) lives entirely inside the `BFSolver`
instance, so concurrent calls do not interfere.

---

## Installation

1. Copy the entire `AutoCut/` folder into your SketchUp plugins directory:
   - macOS: `~/Library/Application Support/SketchUp <version>/SketchUp/Plugins/`
   - Windows: `%APPDATA%\SketchUp\SketchUp <version>\SketchUp\Plugins\`
2. Restart SketchUp.
3. The tool appears under **Extensions → AutoCut & BOM**.

## Requirements

- SketchUp 2017 or later (requires `UI::HtmlDialog`)
- Ruby 2.2+ (bundled with SketchUp)
