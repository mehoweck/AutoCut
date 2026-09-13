# autocut/optimizer.rb
# 1-D bin-packing optimizer for stock cutting.
#
# Public API:
#   Optimizer.optimize(pieces, lengths, cut_loss, solver: GREEDY) → { bins:, unfit: }
#   Optimizer.optimize_by_cross(aggregated, lengths, cut_loss, solver: GREEDY)
#     → { cross_section_string => { bins:, unfit_count: } }
#   Optimizer.build_order(cross_results) → { cross => { source_len => count } }
#
# Built-in solvers (respond to #call(pieces, lengths, cut_loss) → bins):
#   Optimizer::GREEDY       — greedy first-fit decreasing, O(n²), fast
#   Optimizer::BRUTE_FORCE  — exhaustive DFS with pruning, falls back to greedy above BF_LIMIT bins

module AutoCut
  module Optimizer
    # Tolerance for floating-point bin-space comparisons [cm].
    FLOAT_EPS = 0.0001

    # Low-level primitive: optimizes a flat list of pieces against available lengths.
    # Returns { bins: Array, unfit: Array }.
    # Each bin: { source_len: Float, cuts: [Float], rest: Float }
    def self.optimize(pieces, lengths, cut_loss, solver: GREEDY)
      return { bins: [], unfit: [] } if pieces.empty? || lengths.empty?

      max_len = lengths.max
      unfit   = pieces.select { |p| p > max_len - cut_loss + FLOAT_EPS }
      fit     = pieces.reject { |p| p > max_len - cut_loss + FLOAT_EPS }
      bins    = fit.empty? ? [] : solver.call(fit.sort.reverse, lengths, cut_loss)
      { bins: bins, unfit: unfit }
    end

    # Optimizes all pieces of each cross-section together, so pieces from different
    # component definitions sharing the same cross-section can fill the same stock piece.
    # Returns { cross_section_string => { bins: Array, unfit_count: Integer } }
    def self.optimize_by_cross(aggregated, lengths, cut_loss, solver: GREEDY)
      return {} if lengths.empty?

      aggregated.group_by { |g| g[:cross] }.each_with_object({}) do |(cross, groups), results|
        next if cross == 'N/A'

        pieces = groups.flat_map { |g|
          len = g[:length_cm].to_f
          len > 0 ? Array.new(g[:count], len) : []
        }
        next if pieces.empty?

        result = optimize(pieces, lengths, cut_loss, solver: solver)
        results[cross] = { bins: result[:bins], unfit_count: result[:unfit].size }
      end
    end

    # Resolves a solver name string (e.g. 'bf') to the corresponding solver object.
    def self.solver_for(name)
      name.to_s == 'bf' ? BRUTE_FORCE : GREEDY
    end

    # Builds order summary: { cross_section_string => { source_length => piece_count } }
    def self.build_order(cross_results)
      cross_results.each_with_object({}) do |(cross, result), order|
        order[cross] = {}
        result[:bins].each do |bin|
          sl = bin[:source_len]
          order[cross][sl] = (order[cross][sl] || 0) + 1
        end
      end
    end

    # ── Solvers ───────────────────────────────────────────────────────────────

    # Greedy first-fit decreasing.
    # Pieces are sorted largest-first and placed into the tightest bin that still fits.
    # O(n²) over bins — fast enough for typical BOM sizes.
    class Greedy
      def call(pieces, lengths, cut_loss)
        bins = []
        pieces.each do |piece|
          best_bin = nil
          best_fit = nil
          bins.each do |bin|
            space = bin[:rest] - cut_loss - piece
            if space >= -Optimizer::FLOAT_EPS && (best_fit.nil? || space < best_fit)
              best_fit = space
              best_bin = bin
            end
          end

          if best_bin
            best_bin[:cuts] << piece
            best_bin[:rest]  = (best_bin[:rest] - cut_loss - piece).round(4)
          else
            src = lengths.find { |l| l >= piece + cut_loss }
            next unless src
            bins << { source_len: src, cuts: [piece], rest: (src - piece).round(4) }
          end
        end
        bins
      end
    end

    # Brute-force exhaustive search with branch pruning and symmetry deduplication.
    # Runs greedy first; skips the BF search if the greedy result already exceeds BF_LIMIT bins
    # (too many bins make the search intractable). Returns the cheaper of the two solutions.
    class BruteForce
      def call(pieces, lengths, cut_loss)
        greedy = Greedy.new.call(pieces, lengths, cut_loss)
        return greedy if greedy.size > AutoCut::BF_LIMIT

        bf = BFSolver.new(pieces, lengths, cut_loss, greedy).solve
        bf_cost     = bf.reduce(0.0)     { |s, b| s + b[:source_len] }
        greedy_cost = greedy.reduce(0.0) { |s, b| s + b[:source_len] }
        bf_cost < greedy_cost ? bf : greedy
      end
    end

    GREEDY      = Greedy.new.freeze
    BRUTE_FORCE = BruteForce.new.freeze

    # ── BFSolver ──────────────────────────────────────────────────────────────

    # Recursive brute-force solver. Encapsulated in a class so that search state
    # (@best, @best_cost) is local to each solve call and never leaks to the module.
    class BFSolver
      def initialize(pieces, lengths, cut_loss, greedy_fallback)
        @pieces    = pieces
        @lengths   = lengths
        @cut_loss  = cut_loss
        @fallback  = greedy_fallback
        @best_cost = nil
        @best      = nil
      end

      def solve
        recurse(0, [])
        @best || @fallback
      end

      private

      def recurse(idx, bins)
        if idx == @pieces.size
          cost = bins.reduce(0.0) { |s, b| s + b[:source_len] }
          if @best_cost.nil? || cost < @best_cost
            @best_cost = cost
            @best      = bins.map { |b| { source_len: b[:source_len], cuts: b[:cuts].dup, rest: b[:rest] } }
          end
          return
        end

        piece        = @pieces[idx]
        current_cost = bins.reduce(0.0) { |s, b| s + b[:source_len] }
        return if @best_cost && current_cost >= @best_cost  # prune worse branches

        # Option A: place piece into an existing bin (deduplicate by remaining space)
        seen = {}
        bins.each do |bin|
          space = bin[:rest] - @cut_loss - piece
          next if space < -Optimizer::FLOAT_EPS
          key = bin[:rest].round(3)
          next if seen[key]
          seen[key]  = true
          old_cuts   = bin[:cuts].dup
          old_rest   = bin[:rest]
          bin[:cuts] << piece
          bin[:rest]  = space.round(4)
          recurse(idx + 1, bins)
          bin[:cuts] = old_cuts
          bin[:rest] = old_rest
        end

        # Option B: open a new bin (deduplicate by source length)
        used = {}
        @lengths.each do |src|
          next if src < piece - Optimizer::FLOAT_EPS
          next if used[src]
          used[src] = true
          bins << { source_len: src, cuts: [piece], rest: (src - piece).round(4) }
          recurse(idx + 1, bins)
          bins.pop
        end
      end
    end
  end
end
