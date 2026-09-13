# autoCut.rb
# Lista komponentow SketchUp v4  (Ruby 2.2 compatible)
#
# Funkcje:
#   - skanowanie zaznaczonej grupy lub calego modelu (auto-fallback)
#   - widok per instancja (wymiary, rotacja, walidacja)
#   - widok zagregowany z optymalizacja cięcia (bin-packing)
#   - dostepne dlugosci listew podawane jako lista, np. 100,150,200,300
#   - optymalizacja: brute-force (<=12 listew) lub greedy (fallback)
#   - kazdy przekroj optymalizowany osobno
#   - podsumowanie zamowienia per przekroj i dlugosc listwy
#   - eksport CSV (separator srednik, UTF-8 BOM)
#   - sortowanie kolumn w tabeli (JS)
#   - tooltips na naglowkach kolumn
#   - zapis ustawien miedzy sesjami (Sketchup.write_default)

require 'sketchup.rb'
require 'csv'

module AutoCut
  extend self

  TOLERANCE_MM   = 1.0
  NAME_REGEX     = /^\d+x\d+/
  PREF_KEY       = "AutoCut"
  DIALOG_TITLE   = "StockCut Optimizer & BOM"
  BF_LIMIT       = 12     # maks. liczba listew dla brute-force

  # ── Ustawienia persystentne ────────────────────────────────────────────────

  def source_lengths_str
    Sketchup.read_default(PREF_KEY, "source_lengths", "200").to_s
  end

  def cut_loss
    Sketchup.read_default(PREF_KEY, "cut_loss", 0.4).to_f
  end

  def use_brute_force
    Sketchup.read_default(PREF_KEY, "use_bf", false)
  end

  def save_settings(src_str, c_loss, bf)
    Sketchup.write_default(PREF_KEY, "source_lengths", src_str.to_s)
    Sketchup.write_default(PREF_KEY, "cut_loss",       c_loss.to_f)
    Sketchup.write_default(PREF_KEY, "use_bf",         bf)
  end

  def parse_lengths(str)
    str.to_s.split(",").map { |s| s.strip.to_f }.select { |v| v > 0 }.sort.uniq
  end

  # ── Entry point ───────────────────────────────────────────────────────────

  def run
    model = Sketchup.active_model
    scope_label, entities = get_entities_to_scan(model)

    instances_data = []
    collect_recursive(entities, instances_data)

    if instances_data.empty?
      UI.messagebox("Nie znaleziono komponentow o nazwie pasującej do wzorca (np. 45x95_legar).")
      return
    end

    aggregated_data = aggregate(instances_data)
    dialog = build_dialog
    setup_callbacks(dialog, instances_data, aggregated_data)

    html = generate_html(instances_data, aggregated_data, scope_label,
                         source_lengths_str, cut_loss)
    dialog.set_html(html)
    dialog.show
  end

  # ── Zakres skanowania ─────────────────────────────────────────────────────

  def get_entities_to_scan(model)
    sel = model.selection
    if !sel.empty? && sel.first.is_a?(Sketchup::Group)
      grp_name = sel.first.name.empty? ? "(bez nazwy)" : sel.first.name
      ["zaznaczona grupa: \"#{grp_name}\"", sel.first.entities]
    else
      ["caly model", model.entities]
    end
  end

  # ── Zbieranie danych per instancja ────────────────────────────────────────

  def collect_recursive(entities, result)
    entities.each do |entity|
      if entity.is_a?(Sketchup::ComponentInstance)
        name = entity.definition.name
        result << extract_instance_data(entity) if name =~ NAME_REGEX
        collect_recursive(entity.definition.entities, result)
      elsif entity.is_a?(Sketchup::Group)
        collect_recursive(entity.entities, result)
      end
    end
  end

  def extract_instance_data(instance)
    name = instance.definition.name
    m      = name.match(/^(\d+)x(\d+)/)
    name_a = m ? m[1].to_f : nil
    name_b = m ? m[2].to_f : nil

    ta = instance.transformation.to_a
    sx = Math.sqrt(ta[0]**2 + ta[1]**2 + ta[2]**2).round(6)
    sy = Math.sqrt(ta[4]**2 + ta[5]**2 + ta[6]**2).round(6)
    sz = Math.sqrt(ta[8]**2 + ta[9]**2 + ta[10]**2).round(6)

    bounds  = instance.definition.bounds
    dims_mm = [
      (bounds.width.to_mm  * sx).round(2),
      (bounds.height.to_mm * sy).round(2),
      (bounds.depth.to_mm  * sz).round(2)
    ]
    length_mm = extract_length(dims_mm, name_a, name_b)

    rot_z = (Math.atan2(ta[1],  ta[0])  * 180.0 / Math::PI).round(2)
    rot_x = (Math.atan2(-ta[2], Math.sqrt(ta[6]**2 + ta[10]**2)) * 180.0 / Math::PI).round(2)
    rot_y = (Math.atan2(ta[8],  ta[10]) * 180.0 / Math::PI).round(2)

    valid = validate_dims(dims_mm, name_a, name_b)

    {
      :name      => name,
      :name_a    => name_a,
      :name_b    => name_b,
      :dim_w     => dims_mm[0],
      :dim_h     => dims_mm[1],
      :dim_d     => dims_mm[2],
      :length_mm => length_mm,
      :rot_x     => rot_x,
      :rot_y     => rot_y,
      :rot_z     => rot_z,
      :valid     => valid
    }
  end

  def extract_length(dims_mm, name_a, name_b)
    sorted = dims_mm.sort.reverse
    return sorted[0] unless name_a && name_b
    cross = [name_a, name_b].sort
    found = sorted.find { |d| !cross.any? { |c| (d - c).abs <= TOLERANCE_MM } }
    (found || sorted[0]).round(2)
  end

  def validate_dims(dims_mm, name_a, name_b)
    return true unless name_a && name_b
    [name_a, name_b].all? { |c| dims_mm.any? { |d| (d - c).abs <= TOLERANCE_MM } }
  end

  # ── Agregacja per definicja ───────────────────────────────────────────────

  def aggregate(instances)
    groups = {}
    instances.each do |inst|
      key = inst[:name]
      if groups[key]
        groups[key][:count] += 1
        groups[key][:invalid_count] += 1 unless inst[:valid]
      else
        len_cm = inst[:length_mm] ? (inst[:length_mm] / 10.0).round(1) : nil
        cross  = (inst[:name_a] && inst[:name_b]) ?
                 "#{inst[:name_a].to_i}x#{inst[:name_b].to_i}" : "N/A"
        groups[key] = {
          :name          => key,
          :cross         => cross,
          :length_cm     => len_cm,
          :count         => 1,
          :invalid_count => inst[:valid] ? 0 : 1
        }
      end
    end
    groups.values.sort_by { |g| g[:name] }
  end

  # ── Bin-packing optimizer ─────────────────────────────────────────────────
  #
  # Wejście:
  #   pieces   — Array of Float: długości do wycięcia [cm] (może zawierać duplikaty)
  #   lengths  — Array of Float: dostępne długości listew, posortowane rosnąco
  #   cut_loss — Float: strata na każde cięcie [cm]
  #
  # Wyjście:
  #   Array of { :source_len => Float, :cuts => [Float], :rest => Float }
  #   Każdy element = jedna zamówiona listwa + co na niej leży + reszta

  def optimize(pieces, lengths, cut_loss, use_bf = false)
    return { :bins => [], :unfit => [] } if pieces.empty? || lengths.empty?
    max_len = lengths.max
    unfit   = pieces.select { |p| p > max_len - cut_loss + 0.0001 }
    fit     = pieces.reject { |p| p > max_len - cut_loss + 0.0001 }
    bins    = fit.empty? ? [] : _bf_or_greedy(fit.sort.reverse, lengths, cut_loss, use_bf)
    { :bins => bins, :unfit => unfit }
  end

  def _bf_or_greedy(pieces, lengths, cut_loss, use_bf = false)
    greedy_result = _greedy(pieces, lengths, cut_loss)
    if use_bf && greedy_result.size <= BF_LIMIT
      bf_result   = _brute_force(pieces, lengths, cut_loss)
      cost_bf     = bf_result.map     { |b| b[:source_len] }.reduce(0.0, :+)
      cost_greedy = greedy_result.map { |b| b[:source_len] }.reduce(0.0, :+)
      cost_bf < cost_greedy ? bf_result : greedy_result
    else
      greedy_result
    end
  end

  # Greedy first-fit decreasing
  def _greedy(pieces, lengths, cut_loss)
    bins = []   # Array of { :source_len, :cuts, :rest }
    pieces.each do |piece|
      # Znajdź istniejący bin z wystarczającą resztą, preferuj najciaśniejszy
      best_bin = nil
      best_fit = nil
      bins.each do |bin|
        space = bin[:rest] - cut_loss - piece
        if space >= -0.0001
          if best_fit.nil? || space < best_fit
            best_fit = space
            best_bin = bin
          end
        end
      end

      if best_bin
        best_bin[:cuts]  << piece
        best_bin[:rest]  = (best_bin[:rest] - cut_loss - piece).round(4)
      else
        # Otwórz nowy bin — wybierz najkrótszą listew która pomieści element
        src = lengths.find { |l| l >= piece + cut_loss }
        next unless src   # nie powinno się zdarzyć po odfiltrowaniu unfit, ale dla bezpieczeństwa
        bins << {
          :source_len => src,
          :cuts       => [piece],
          :rest       => (src - piece).round(4)
        }
      end
    end
    bins
  end

  # Brute force — rekurencyjnie przypisuje każdy element do istniejącego lub nowego binu
  # Zwraca układ z minimalnym łącznym kosztem (sumą długości listew)
  def _brute_force(pieces, lengths, cut_loss)
    @_bf_best_cost = nil
    @_bf_best      = nil
    _bf_recurse(pieces, 0, [], lengths, cut_loss)
    @_bf_best || _greedy(pieces, lengths, cut_loss)
  end

  def _bf_recurse(pieces, idx, bins, lengths, cut_loss)
    if idx == pieces.size
      cost = bins.map { |b| b[:source_len] }.reduce(0.0, :+)
      if @_bf_best_cost.nil? || cost < @_bf_best_cost
        @_bf_best_cost = cost
        @_bf_best      = bins.map { |b|
          { :source_len => b[:source_len],
            :cuts       => b[:cuts].dup,
            :rest       => b[:rest] }
        }
      end
      return
    end

    piece = pieces[idx]

    # Odcinaj gałęzie gorsze niż dotychczasowe optimum
    current_cost = bins.map { |b| b[:source_len] }.reduce(0.0, :+)
    return if @_bf_best_cost && current_cost >= @_bf_best_cost

    # Opcja A: dołóż do istniejącego binu
    seen_rests = {}
    bins.each_with_index do |bin, i|
      space = bin[:rest] - cut_loss - piece
      next if space < -0.0001
      # Deduplikacja: nie próbuj binów z identyczną resztą (symetria)
      rest_key = bin[:rest].round(3)
      next if seen_rests[rest_key]
      seen_rests[rest_key] = true

      old_cuts = bin[:cuts].dup
      old_rest = bin[:rest]
      bin[:cuts] << piece
      bin[:rest]  = space.round(4)
      _bf_recurse(pieces, idx + 1, bins, lengths, cut_loss)
      bin[:cuts] = old_cuts
      bin[:rest] = old_rest
    end

    # Opcja B: otwórz nowy bin (tylko dla każdej unikalnej długości listwy)
    used_src_lens = {}
    lengths.each do |src|
      next if src < piece - 0.0001
      next if used_src_lens[src]
      used_src_lens[src] = true
      new_bin = {
        :source_len => src,
        :cuts       => [piece],
        :rest       => (src - piece).round(4)
      }
      bins << new_bin
      _bf_recurse(pieces, idx + 1, bins, lengths, cut_loss)
      bins.pop
    end
  end

  # ── Przeliczanie i podsumowanie ───────────────────────────────────────────

  # Dla każdej definicji uruchamia optymalizator i dołącza wynik :bins
  def calc_optimized(aggregated, lengths, c_loss, use_bf = false)
    aggregated.map do |g|
      len = g[:length_cm].to_f
      if len > 0 && g[:count] > 0 && !lengths.empty?
        pieces = Array.new(g[:count], len)
        result = optimize(pieces, lengths, c_loss, use_bf)
        bins   = result[:bins]
        unfit  = result[:unfit].size
      else
        bins  = []
        unfit = 0
      end
      g.merge(:bins => bins, :unfit_count => unfit, :opt_lengths => lengths)
    end
  end

  # Podsumowanie zamówienia: { cross => { src_len => count } }
  def build_order(agg_opt)
    order = {}
    agg_opt.each do |g|
      cross = g[:cross]
      order[cross] ||= {}
      g[:bins].each do |bin|
        sl = bin[:source_len]
        order[cross][sl] ||= 0
        order[cross][sl]  += 1
      end
    end
    order
  end

  # ── Dialog ────────────────────────────────────────────────────────────────

  def build_dialog
    UI::HtmlDialog.new(
      :dialog_title    => DIALOG_TITLE,
      :preferences_key => PREF_KEY,
      :scrollable      => true,
      :resizable       => true,
      :width           => 900,
      :height          => 700,
      :left            => 150,
      :top             => 100,
      :min_width       => 700,
      :min_height      => 450,
      :max_width       => 1400,
      :max_height      => 1000,
      :style           => UI::HtmlDialog::STYLE_DIALOG
    )
  end

  # ── Callbacki JS -> Ruby ─────────────────────────────────────────────────

  def setup_callbacks(dialog, instances_data, aggregated_data)
    dialog.add_action_callback("recalculate") do |_, params|
      # params: "200,300|0.4|bf"  lub  "200,300|0.4|greedy"
      parts       = params.to_s.split("|")
      next unless parts.size >= 2
      lengths_str = parts[0]
      c_loss_val  = parts[1].to_f
      bf_val      = parts[2].to_s == "bf"
      lengths     = parse_lengths(lengths_str)
      next if lengths.empty? || c_loss_val < 0
      save_settings(lengths_str, c_loss_val, bf_val)

      agg_opt  = calc_optimized(aggregated_data, lengths, c_loss_val, bf_val)
      order    = build_order(agg_opt)
      js_agg   = agg_opt.map   { |g| agg_row_js(g) }.join(",")
      js_order = order_js(order, lengths)
      js_mbvol = mb_volume_js(agg_opt)
      dialog.execute_script("updateAggregated([#{js_agg}])")
      dialog.execute_script("updateOrderSummary(#{js_order})")
      dialog.execute_script("updateMbVolume(#{js_mbvol})")
    end

    dialog.add_action_callback("save_instances_csv") do |_|
      save_instances_csv(instances_data)
    end

    dialog.add_action_callback("save_aggregated_csv") do |_|
      lengths = parse_lengths(source_lengths_str)
      lengths = [200.0] if lengths.empty?
      agg_opt = calc_optimized(aggregated_data, lengths, cut_loss, use_brute_force)
      order   = build_order(agg_opt)
      save_aggregated_csv(agg_opt, order, lengths)
    end
  end

  # ── Serializacja JS ───────────────────────────────────────────────────────

  # Jeden wiersz zagregowany do JSON — zawiera bins jako lista przycięć
  def agg_row_js(g)
    inv      = g[:invalid_count] > 0
    unfit    = g[:unfit_count].to_i > 0
    bins_js  = g[:bins].map do |bin|
      cuts_js = bin[:cuts].map { |c| c.to_s }.join(",")
      "{\"src\":#{bin[:source_len]},\"cuts\":[#{cuts_js}],\"rest\":#{bin[:rest]}}"
    end.join(",")
    "{" +
    "\"name\":\"#{esc(g[:name])}\"," +
    "\"cross\":\"#{g[:cross]}\"," +
    "\"length\":\"#{g[:length_cm]}\"," +
    "\"count\":#{g[:count]}," +
    "\"invalid\":#{inv}," +
    "\"unfit\":#{unfit}," +
    "\"bins\":[#{bins_js}]}"
  end

  # Order summary do JSON: [{ cross, sl, count, mb }, ...]
  # Plus mb_summary: { cross => total_mb } i volume_summary: { cross => m3 }
  def order_js(order, lengths)
    rows = []
    order.keys.sort.each do |cross|
      lengths.each do |sl|
        cnt = order[cross][sl]
        next unless cnt && cnt > 0
        mb = (cnt * sl / 100.0).round(2)
        rows << "{\"cross\":\"#{esc(cross)}\",\"sl\":#{sl},\"count\":#{cnt},\"mb\":#{mb}}"
      end
    end
    "[" + rows.join(",") + "]"
  end

  # mb i kubatura per przekrój — na podstawie danych zagregowanych (nie binów)
  def mb_volume_js(agg_opt)
    by_cross = {}
    agg_opt.each do |g|
      cross = g[:cross]
      next if cross == "N/A"
      len_cm = g[:length_cm].to_f
      next if len_cm <= 0
      by_cross[cross] ||= 0.0
      by_cross[cross] += g[:count] * len_cm / 100.0
    end
    rows = by_cross.keys.sort.map do |cross|
      mb  = by_cross[cross].round(3)
      m3  = calc_volume_m3(cross, mb)
      "{\"cross\":\"#{esc(cross)}\",\"mb\":#{mb},\"m3\":#{m3}}"
    end
    "[" + rows.join(",") + "]"
  end

  # Oblicza kubaturę m3 na podstawie przekroju (string "45x95") i długości w mb
  def calc_volume_m3(cross_str, mb)
    m = cross_str.match(/^(\d+)x(\d+)$/)
    return 0.0 unless m
    a_m = m[1].to_f / 1000.0
    b_m = m[2].to_f / 1000.0
    (mb * a_m * b_m).round(6)
  end

  def esc(str)
    str.to_s.gsub('\\', '\\\\').gsub('"', '\\"').gsub("\n", '').gsub("\r", '')
  end

  # ── Eksport CSV ───────────────────────────────────────────────────────────

  def save_instances_csv(data)
    path = UI.savepanel("Zapisz jako CSV", Dir.home, "komponenty_instancje.csv")
    return unless path
    path += ".csv" unless path.downcase.end_with?(".csv")
    begin
      File.open(path, "w:UTF-8") do |f|
        f.write("\xEF\xBB\xBF")
        f.puts %w[Nazwa Dlugosc_mm Sz_rzecz_mm Wys_rzecz_mm Gl_rzecz_mm
                  Rot_X Rot_Y Rot_Z Zgodny].join(";")
        data.each do |i|
          f.puts [
            i[:name], i[:length_mm],
            i[:dim_w], i[:dim_h], i[:dim_d],
            i[:rot_x], i[:rot_y], i[:rot_z],
            i[:valid] ? "TAK" : "NIE"
          ].join(";")
        end
      end
      UI.messagebox("Zapisano: #{path}")
    rescue => e
      UI.messagebox("Blad zapisu: #{e.message}")
    end
  end

  def save_aggregated_csv(agg_opt, order, lengths)
    path = UI.savepanel("Zapisz jako CSV", Dir.home, "komponenty_agregowane.csv")
    return unless path
    path += ".csv" unless path.downcase.end_with?(".csv")
    begin
      File.open(path, "w:UTF-8") do |f|
        f.write("\xEF\xBB\xBF")
        f.puts "# Dostepne dlugosci listew: #{lengths.join(', ')} cm | Strata na ciecie: #{cut_loss} cm"
        f.puts ""

        # Sekcja szczegółów
        f.puts "## SZCZEGOLY"
        f.puts %w[Nazwa Przekroj Dlugosc_cm Szt Niezgodne Listwy_plan].join(";")
        agg_opt.each do |g|
          plan = g[:bins].map { |b| "#{b[:source_len].to_i}cm(#{b[:cuts].map{|c|c.to_i}.join('+')})" }.join(", ")
          f.puts [g[:name], g[:cross], g[:length_cm], g[:count],
                  g[:invalid_count], plan].join(";")
        end

        f.puts ""

        # Sekcja zamówienia (listwy)
        f.puts "## ZAMOWIENIE"
        f.puts %w[Przekroj Dlugosc_listwy_cm Liczba_listew Lacznie_mb].join(";")
        order.keys.sort.each do |cross|
          lengths.each do |sl|
            cnt = order[cross][sl]
            next unless cnt && cnt > 0
            mb = (cnt * sl / 100.0).round(2)
            f.puts [cross, sl.to_i, cnt, mb].join(";")
          end
        end

        f.puts ""

        # Metry bieżące
        f.puts "## METRY BIEZACE"
        f.puts %w[Przekroj Lacznie_mb].join(";")
        by_cross = {}
        agg_opt.each do |g|
          next if g[:cross] == "N/A"
          len_cm = g[:length_cm].to_f
          next if len_cm <= 0
          by_cross[g[:cross]] ||= 0.0
          by_cross[g[:cross]]  += g[:count] * len_cm / 100.0
        end
        by_cross.keys.sort.each do |cross|
          f.puts [cross, by_cross[cross].round(3)].join(";")
        end

        f.puts ""

        # Kubatura
        f.puts "## KUBATURA"
        f.puts %w[Przekroj Kubatura_m3].join(";")
        by_cross.keys.sort.each do |cross|
          mb = by_cross[cross].round(3)
          f.puts [cross, calc_volume_m3(cross, mb)].join(";")
        end
      end
      UI.messagebox("Zapisano: #{path}")
    rescue => e
      UI.messagebox("Blad zapisu: #{e.message}")
    end
  end

  # ── Generowanie HTML ──────────────────────────────────────────────────────

  def generate_html(instances, aggregated, scope_label, src_lengths_str, c_loss)
    lengths       = parse_lengths(src_lengths_str)
    lengths       = [200.0] if lengths.empty?
    bf            = use_brute_force
    agg_opt       = calc_optimized(aggregated, lengths, c_loss, bf)
    order         = build_order(agg_opt)

    instances_rows = agg_opt.map    { |g| instance_row_html(g) }.join("\n")
    agg_rows       = agg_opt.map   { |g| agg_row_html(g) }.join("\n")
    order_rows     = order_summary_html(order, lengths)
    mbvol_rows     = mb_volume_html(agg_opt)

    invalid_count  = instances.count { |i| !i[:valid] }
    total_count    = instances.size
    agg_count      = agg_opt.size
    inv_badge      = invalid_count > 0 ?
      " &nbsp;<span style='color:#e74c3c'>&#9888; #{invalid_count} niezgodnych</span>" : ""

    "<!DOCTYPE html>\n" +
    "<html lang='pl'>\n<head>\n<meta charset='UTF-8'>\n" +
    "<title>" + DIALOG_TITLE + "</title>\n" +
    build_css +
    "</head>\n<body>\n" +
    build_topbar(scope_label, total_count, inv_badge, src_lengths_str, c_loss, agg_count, bf) +
    build_tables(instances_rows, agg_rows, order_rows, mbvol_rows) +
    "<div id='footer'>Sortuj: kliknij naglowek kolumny &nbsp;|&nbsp; " +
    "Czerwone wiersze = rozbiez. nazwa vs bbox &gt; #{TOLERANCE_MM.to_i} mm</div>\n" +
    build_js +
    "</body>\n</html>"
  end

  # ── CSS ───────────────────────────────────────────────────────────────────

  def build_css
    "<style>\n" +
    "*, *::before, *::after{box-sizing:border-box;margin:0;padding:0}\n" +
    "body{font-family:Arial,sans-serif;font-size:12px;background:#f0f0f0;color:#222}\n" +
    "#topbar{display:flex;align-items:center;gap:6px;padding:5px 8px;" +
      "background:#2c3e50;color:#ecf0f1;position:sticky;top:0;z-index:100;flex-wrap:wrap}\n" +
    "#topbar h2{font-size:13px;font-weight:bold}\n" +
    ".scope-label{font-size:11px;color:#bdc3c7;margin-right:auto}\n" +
    ".tab-btn{padding:3px 10px;border:1px solid #7f8c8d;background:transparent;" +
      "color:#ecf0f1;cursor:pointer;border-radius:3px;font-size:12px}\n" +
    ".tab-btn.active{background:#27ae60;border-color:#27ae60;font-weight:bold}\n" +
    ".save-btn{padding:3px 10px;background:#2980b9;border:none;color:white;" +
      "cursor:pointer;border-radius:3px;font-size:12px}\n" +
    ".save-btn:hover{background:#3498db}\n" +
    "#agg-controls{display:none;align-items:center;gap:6px;padding:4px 8px;" +
      "background:#ecf0f1;border-bottom:1px solid #bdc3c7;flex-wrap:wrap}\n" +
    "#agg-controls label{font-size:11px;color:#555}\n" +
    "#agg-controls input{padding:2px 4px;border:1px solid #aaa;" +
      "border-radius:3px;font-size:12px}\n" +
    ".recalc-btn{padding:3px 10px;background:#27ae60;border:none;color:white;" +
      "cursor:pointer;border-radius:3px;font-size:12px}\n" +
    ".recalc-btn:hover{background:#2ecc71}\n" +
    ".stats-label{font-size:11px;color:#888;margin-left:auto}\n" +
    ".view{display:none;padding:6px}\n" +
    ".view.active{display:block}\n" +
    "table{width:100%;border-collapse:collapse;background:white;" +
      "box-shadow:0 1px 3px rgba(0,0,0,.15)}\n" +
    "th,td{border:1px solid #ddd;padding:3px 6px;white-space:nowrap}\n" +
    "th{background:#2c3e50;color:#ecf0f1;font-weight:bold;position:sticky;" +
      "top:30px;cursor:pointer;user-select:none;text-align:center}\n" +
    "th:hover{background:#34495e}\n" +
    "th.sorted-asc::after{content:' \u25b2';font-size:9px}\n" +
    "th.sorted-desc::after{content:' \u25bc';font-size:9px}\n" +
    "td{text-align:right}\n" +
    "td.name-col{text-align:left;font-family:'Courier New',monospace;font-size:11px;" +
      "max-width:220px;overflow:hidden;text-overflow:ellipsis}\n" +
    "td.plan-col{text-align:left;font-size:10px;font-family:'Courier New',monospace;" +
      "color:#444}\n" +
    "#tbl-agg{table-layout:auto;width:100%}\n" +
    "#tbl-agg th,#tbl-agg td{width:auto;white-space:nowrap}\n" +
    "#tbl-agg th:first-child,#tbl-agg td:first-child{min-width:140px}\n" +
    "#tbl-agg .plan-col{white-space:normal;min-width:180px;max-width:400px;word-break:break-all}\n" +
    "tr:nth-child(even) td{background:#f7f9fa}\n" +
    "tr:hover td{background:#eaf4fb!important}\n" +
    "tr.row-invalid td{background:#fff0f0!important}\n" +
    "tr.row-invalid td.name-col{color:#c0392b;font-weight:bold}\n" +
    "tr.row-invalid:hover td{background:#ffe0e0!important}\n" +
    ".section-title{display:flex;align-items:center;gap:6px;" +
      "font-size:12px;font-weight:600;color:#555;margin:16px 0 6px 0;letter-spacing:.03em}\n" +
    ".section-title span.icon{font-size:13px}\n" +
    ".summary-table{width:auto;min-width:280px;border-collapse:collapse;" +
      "background:white;box-shadow:0 1px 3px rgba(0,0,0,.1)}\n" +
    ".summary-table th,.summary-table td{border:1px solid #ddd;padding:3px 8px;white-space:nowrap}\n" +
    ".summary-table th{background:#2c3e50;color:#ecf0f1;font-weight:bold;" +
      "cursor:default;text-align:center}\n" +
    ".summary-table td{text-align:right}\n" +
    ".summary-table td.name-col{text-align:left}\n" +
    ".summary-table tr:nth-child(even) td{background:#f7f9fa}\n" +
    ".summary-table tr:hover td{background:#eaf4fb!important}\n" +
    "tr.order-sep td{padding:0;border:none;background:#f0f0f0;height:4px}\n" +
    "tr.order-total td{font-weight:bold;background:#eafaf1!important}\n" +
    "#footer{padding:5px 8px;font-size:11px;color:#888;" +
      "border-top:1px solid #ddd;background:#fafafa}\n" +
    "</style>\n"
  end

  # ── Topbar + controls ─────────────────────────────────────────────────────

  def build_topbar(scope_label, total_count, inv_badge, src_lengths_str, c_loss, agg_count, bf = false)
    bf_selected     = bf ? " selected" : ""
    greedy_selected = bf ? "" : " selected"
    "<div id='topbar'>\n" +
    "<h2>" + DIALOG_TITLE + "</h2>\n" +
    "<span class='scope-label'>&#128269; " + scope_label +
      " &nbsp;|&nbsp; " + total_count.to_s + " elementow" + inv_badge + "</span>\n" +
    "<button class='tab-btn active' id='btn-inst' onclick='switchTab(\"instances\")'>Elementy</button>\n" +
    "<button class='tab-btn' id='btn-agg' onclick='switchTab(\"aggregated\")'>Zam\u00f3wienie</button>\n" +
    "<button class='save-btn' onclick='doSave()'>&#128190; Save CSV</button>\n" +
    "</div>\n" +
    "<div id='inst-controls' style='display:flex;align-items:center;gap:6px;padding:4px 8px;" +
      "background:#ecf0f1;border-bottom:1px solid #bdc3c7'>\n" +
    "<label style='font-size:11px;color:#555'>Jednostki:</label>\n" +
    "<select id='unit-select' onchange='changeUnit()' style='font-size:12px;padding:2px 4px;" +
      "border:1px solid #aaa;border-radius:3px'>\n" +
    "<option value='cm' selected>centymetry [cm]</option>\n" +
    "<option value='mm'>milimetry [mm]</option>\n" +
    "<option value='m'>metry [m]</option>\n" +
    "</select>\n" +
    "</div>\n" +
    "<div id='agg-controls' style='display:none'>\n" +
    "<label title='Podaj dostepne dlugosci listew oddzielone przecinkiem, np. 100,150,200,300'>Dostepne dlugosci [cm]:</label>\n" +
    "<input id='src-len' type='text' style='width:160px' placeholder='np. 100,150,200,300' value='" + src_lengths_str + "'>\n" +
    "<label title='Grubosc piły lub strata materialu na każde cięcie'>Strata [cm]:</label>\n" +
    "<input id='cut-loss' type='number' min='0' step='0.1' style='width:55px' value='" + c_loss.to_s + "'>\n" +
    "<button class='recalc-btn' onclick='doRecalc()'>&#8635; Przelicz</button>\n" +
    "<select id='algo-select' title='Greedy: szybki, dobry wynik. Brute force: optymalny, wolniejszy (limit #{BF_LIMIT} listew na przekroj).' style='font-size:12px;padding:2px 4px;border:1px solid #aaa;border-radius:3px'>\n" +
    "<option value='greedy'#{greedy_selected}>Greedy</option>\n" +
    "<option value='bf'#{bf_selected}>Brute force</option>\n" +
    "</select>\n" +
    "<span class='stats-label' id='agg-stats'>" + agg_count.to_s + " definicji</span>\n" +
    "</div>\n"
  end

  # ── Tabele ────────────────────────────────────────────────────────────────

  def build_tables(instances_rows, agg_rows, order_rows, mbvol_rows)
    mb_rows  = mbvol_rows[0]
    vol_rows = mbvol_rows[1]
    # Tooltips na nagłówkach Elementy (zgrupowane po nazwie)
    inst_hdr =
      "<th title='Nazwa definicji komponentu' onclick='sortTable(\"tbl-inst\",0,true)'>Nazwa</th>" +
      "<th id='inst-len-hdr' title='Dlugosc elementu wyznaczona z bounding box' onclick='sortTable(\"tbl-inst\",1)'>Dl [cm]</th>" +
      "<th title='Liczba wystapien tego komponentu w modelu' onclick='sortTable(\"tbl-inst\",2)'>Szt</th>" +
      "<th title='Czy wymiary z nazwy (np. 45x95) zgadzaja sie z bounding box (tolerancja 5mm)' onclick='sortTable(\"tbl-inst\",3)'>OK</th>"

    # Tooltips na nagłówkach Aggregated
    agg_hdr =
      "<th title='Nazwa definicji komponentu' onclick='sortTable(\"tbl-agg\",0,true)'>Nazwa</th>" +
      "<th title='Przekroj wyciagniety z nazwy (np. 45x95)' onclick='sortTable(\"tbl-agg\",1)'>Przekroj</th>" +
      "<th title='Dlugosc elementu [cm]' onclick='sortTable(\"tbl-agg\",2)'>Dl<br>[cm]</th>" +
      "<th title='Liczba sztuk w modelu' onclick='sortTable(\"tbl-agg\",3)'>Szt</th>" +
      "<th title='Optymalna dlugosc listwy do zamowienia dla tego elementu' onclick='sortTable(\"tbl-agg\",4)'>Listwa<br>[cm]</th>" +
      "<th title='Liczba listew potrzebnych dla wszystkich sztuk tego elementu' onclick='sortTable(\"tbl-agg\",5)'>Listwy<br>[szt]</th>" +
      "<th title='Plan cięcia: na kazdej listwie jakie elementy' onclick='sortTable(\"tbl-agg\",6,true)'>Plan cięcia</th>" +
      "<th title='Czy wymiary z nazwy zgadzaja sie z bounding box' onclick='sortTable(\"tbl-agg\",7)'>OK</th>"

    "<div class='view active' id='view-instances'>\n" +
    "<table id='tbl-inst'><thead><tr>" + inst_hdr + "</tr></thead>\n" +
    "<tbody id='tbl-inst-body'>\n" + instances_rows + "\n</tbody></table>\n</div>\n" +

    "<div class='view' id='view-aggregated'>\n" +
    "<table id='tbl-agg'><thead><tr>" + agg_hdr + "</tr></thead>\n" +
    "<tbody id='tbl-agg-body'>\n" + agg_rows + "\n</tbody></table>\n" +

    "<div class='section-title'><span class='icon'>&#128722;</span>Podsumowanie zamowienia</div>\n" +
    "<table class='summary-table'><thead><tr>" +
    "<th title='Przekroj materialu'>Przekroj</th>" +
    "<th title='Dlugosc listwy do zamowienia [cm]'>Dlugosc listwy [cm]</th>" +
    "<th title='Liczba listew do zamowienia'>Liczba [szt]</th>" +
    "<th title='Laczna dlugosc listew tego typu [mb]'>Lacznie [mb]</th>" +
    "</tr></thead>\n" +
    "<tbody id='order-body'>\n" + order_rows + "\n</tbody>" +
    "</table>\n" +

    "<div class='section-title'><span class='icon'>&#128207;</span>Metry biezace</div>\n" +
    "<table class='summary-table'><thead><tr>" +
    "<th title='Przekroj materialu'>Przekroj</th>" +
    "<th title='Laczna dlugosc wszystkich elementow danego przekroju [mb]'>Lacznie [mb]</th>" +
    "</tr></thead>\n" +
    "<tbody id='mb-body'>\n" + mb_rows + "\n</tbody>" +
    "</table>\n" +

    "<div class='section-title'><span class='icon'>&#9633;</span>Kubatura</div>\n" +
    "<table class='summary-table'><thead><tr>" +
    "<th title='Przekroj materialu'>Przekroj</th>" +
    "<th title='Laczna objetosc elementow danego przekroju [m3]'>Kubatura [m&#179;]</th>" +
    "</tr></thead>\n" +
    "<tbody id='vol-body'>\n" + vol_rows + "\n</tbody>" +
    "</table>\n" +

    "</div>\n"
  end

  # ── Wiersze HTML ──────────────────────────────────────────────────────────

  # Widok Elementy: jeden wiersz per unikalna nazwa (zgrupowane)
  def instance_row_html(g)
    inv  = g[:invalid_count] > 0
    cls  = inv ? " class='row-invalid'" : ""
    ok   = inv ? "&#9888;" : "&#10003;"
    tip  = inv ? " title='Rozbiez. wymiarow: bbox vs nazwa (#{g[:invalid_count]} szt.)'" : ""
    name = esc(g[:name])
    # Przechowuj długość w mm jako data-atrybut — JS przelicza według wybranych jednostek
    len_mm = g[:length_cm] ? (g[:length_cm].to_f * 10).round(1) : 0
    "<tr#{cls}>" +
    "<td class='name-col'#{tip}>#{name}</td>" +
    "<td class='len-cell' data-mm='#{len_mm}'></td>" +
    "<td><b>#{g[:count]}</b></td>" +
    "<td style='text-align:center'>#{ok}</td>" +
    "</tr>"
  end

  def agg_row_html(g)
    inv   = g[:invalid_count] > 0
    unfit = g[:unfit_count].to_i > 0
    cls   = (inv || unfit) ? " class='row-invalid'" : ""
    ok    = inv ? "&#9888; #{g[:invalid_count]}" : "&#10003;"
    name  = esc(g[:name])
    bins  = g[:bins]

    if unfit
      err_tip = "Element #{g[:length_cm]} cm jest dluzszy niz wszystkie dostepne listwy"
      src_lens = "<span style='color:#c0392b;font-weight:bold' title='#{err_tip}'>Za dlugi!</span>"
      n_bins   = "<span style='color:#c0392b'>&#8212;</span>"
      plan     = "<span style='color:#c0392b' title='#{err_tip}'>Brak pasujacych listew</span>"
    else
      # Kolumna "listwa": unikalne długości listew użyte dla tego elementu
      src_lens = bins.map { |b| b[:source_len] }.uniq.sort
                     .map { |sl| "#{sl.to_i}" }.join(", ")
      src_lens = "&#8212;" if src_lens.empty?

      # Liczba listew łącznie
      n_bins = bins.size > 0 ? bins.size.to_s : "&#8212;"

      # Plan cięcia: "150(130) | 100(40+40)"
      plan = bins.map do |b|
        cuts_str = b[:cuts].map { |c| c.to_i.to_s }.join("+")
        rest_str = b[:rest] > 0.05 ? " r#{b[:rest].to_i}" : ""
        "#{b[:source_len].to_i}(#{cuts_str}#{rest_str})"
      end.join(" | ")
      plan = "&#8212;" if plan.empty?
    end

    "<tr#{cls}>" +
    "<td class='name-col' title='#{name}'>#{name}</td>" +
    "<td>#{g[:cross]}</td>" +
    "<td>#{g[:length_cm]}</td>" +
    "<td><b>#{g[:count]}</b></td>" +
    "<td>#{src_lens}</td>" +
    "<td><b>#{n_bins}</b></td>" +
    "<td class='plan-col' title='#{esc(plan)}'>#{plan}</td>" +
    "<td style='text-align:center'>#{ok}</td>" +
    "</tr>"
  end

  def order_summary_html(order, lengths)
    rows = []
    order.keys.sort.each do |cross|
      lengths.each do |sl|
        cnt = order[cross][sl]
        next unless cnt && cnt > 0
        mb = (cnt * sl / 100.0).round(2)
        rows << "<tr>" +
          "<td class='name-col'>#{esc(cross)}</td>" +
          "<td>#{sl.to_i}</td>" +
          "<td><b>#{cnt}</b></td>" +
          "<td>#{mb}</td>" +
          "</tr>"
      end
      # separator między przekrojami
      rows << "<tr class='order-sep'><td colspan='4' style='padding:0;border:none;" +
              "background:#f0f0f0;height:6px'></td></tr>"
    end
    rows.join("\n")
  end

  # Tabela mb + kubatura (statyczny HTML przy otwarciu)
  def mb_volume_html(agg_opt)
    by_cross = {}
    agg_opt.each do |g|
      cross  = g[:cross]
      next if cross == "N/A"
      len_cm = g[:length_cm].to_f
      next if len_cm <= 0
      by_cross[cross] ||= 0.0
      by_cross[cross]  += g[:count] * len_cm / 100.0
    end
    rows_mb  = []
    rows_vol = []
    by_cross.keys.sort.each do |cross|
      mb  = by_cross[cross].round(3)
      m3  = calc_volume_m3(cross, mb)
      rows_mb  << "<tr><td class='name-col'>#{esc(cross)}</td><td>#{mb}</td></tr>"
      rows_vol << "<tr><td class='name-col'>#{esc(cross)}</td><td>#{m3}</td></tr>"
    end
    [rows_mb.join("\n"), rows_vol.join("\n")]
  end

  # ── JS ────────────────────────────────────────────────────────────────────

  def build_js
    "<script>\n" +
    "var currentTab='instances';\n" +

    # Formatowanie długości wg jednostki
    "function fmtLen(mm,unit){\n" +
    "  if(mm===0||mm==='')return '\u2014';\n" +
    "  var v=parseFloat(mm);\n" +
    "  if(isNaN(v))return '\u2014';\n" +
    "  if(unit==='mm')return Math.round(v)+'';\n" +
    "  if(unit==='cm'){var c=v/10; return c===Math.round(c)?Math.round(c)+'':c.toFixed(1).replace(/\\.0$/,'');}\n" +
    "  if(unit==='m'){var m=v/1000; return m.toFixed(2).replace(/\\.?0+$/,'')+'';}\n" +
    "  return v+'';\n" +
    "}\n" +

    # Zmiana jednostek — przelicza wszystkie komórki len-cell i aktualizuje nagłówek
    "function changeUnit(){\n" +
    "  var unit=document.getElementById('unit-select').value;\n" +
    "  var labels={mm:'Dl [mm]',cm:'Dl [cm]',m:'Dl [m]'};\n" +
    "  document.getElementById('inst-len-hdr').textContent=labels[unit]||'Dl';\n" +
    "  var cells=document.querySelectorAll('#tbl-inst .len-cell');\n" +
    "  cells.forEach(function(td){td.textContent=fmtLen(td.getAttribute('data-mm'),unit);});\n" +
    "}\n" +

    # Init — wypełnij komórki domyślną jednostką (cm) po załadowaniu DOM
    "document.addEventListener('DOMContentLoaded',function(){\n" +
    "  changeUnit();\n" +
    "  ['src-len','cut-loss'].forEach(function(id){\n" +
    "    var el=document.getElementById(id);\n" +
    "    if(el)el.addEventListener('keydown',function(e){if(e.key==='Enter')doRecalc();});\n" +
    "  });\n" +
    "});\n" +

    "function switchTab(tab){\n" +
    "  currentTab=tab;\n" +
    "  var vi=document.getElementById('view-instances');\n" +
    "  var va=document.getElementById('view-aggregated');\n" +
    "  var bi=document.getElementById('btn-inst');\n" +
    "  var ba=document.getElementById('btn-agg');\n" +
    "  var ic=document.getElementById('inst-controls');\n" +
    "  var ac=document.getElementById('agg-controls');\n" +
    "  if(tab==='instances'){\n" +
    "    vi.className='view active'; va.className='view';\n" +
    "    bi.className='tab-btn active'; ba.className='tab-btn';\n" +
    "    ic.style.display='flex'; ac.style.display='none';\n" +
    "  } else {\n" +
    "    va.className='view active'; vi.className='view';\n" +
    "    ba.className='tab-btn active'; bi.className='tab-btn';\n" +
    "    ac.style.display='flex'; ic.style.display='none';\n" +
    "  }\n" +
    "}\n" +

    "function doSave(){\n" +
    "  if(currentTab==='instances'){sketchup.save_instances_csv();}\n" +
    "  else{sketchup.save_aggregated_csv();}\n" +
    "}\n" +

    "function doRecalc(){\n" +
    "  var s=document.getElementById('src-len').value.trim();\n" +
    "  var l=parseFloat(document.getElementById('cut-loss').value);\n" +
    "  var bf=document.getElementById('algo-select').value;\n" +
    "  if(!s){alert('Podaj dlugosci listew, np. 100,150,200');return;}\n" +
    "  if(isNaN(l)||l<0){alert('Strata musi byc >= 0.');return;}\n" +
    "  sketchup.recalculate(s+'|'+l+'|'+bf);\n" +
    "}\n" +


    # updateAggregated
    "function updateAggregated(rows){\n" +
    "  var tbody=document.getElementById('tbl-agg-body');\n" +
    "  tbody.innerHTML='';\n" +
    "  rows.forEach(function(g){\n" +
    "    var rowErr=(g.invalid||g.unfit)?'row-invalid':'';\n" +
    "    var ok=g.invalid?'&#9888;':'&#10003;';\n" +
    "    var srcLens,nBins,plan;\n" +
    "    if(g.unfit){\n" +
    "      srcLens='<span style=\"color:#c0392b;font-weight:bold\" title=\"Element '+g.length+' cm jest dluzszy niz dostepne listwy\">Za dlugi!</span>';\n" +
    "      nBins='<span style=\"color:#c0392b\">&mdash;</span>';\n" +
    "      plan='<span style=\"color:#c0392b\">Brak pasujacych listew</span>';\n" +
    "    } else {\n" +
    "      srcLens=[...new Set(g.bins.map(function(b){return b.src;}))].sort().map(function(s){return Math.round(s);}).join(', ')||'&mdash;';\n" +
    "      nBins=g.bins.length||'&mdash;';\n" +
    "      plan=g.bins.map(function(b){\n" +
    "        var cuts=b.cuts.map(function(c){return Math.round(c);}).join('+');\n" +
    "        var rest=b.rest>0.05?(' r'+Math.round(b.rest)):'';\n" +
    "        return Math.round(b.src)+'('+cuts+rest+')';\n" +
    "      }).join(' | ')||'&mdash;';\n" +
    "    }\n" +
    "    var tr='<tr class=\"'+rowErr+'\">'+" +
    "      '<td class=\"name-col\" title=\"'+g.name+'\">'+g.name+'</td>'+" +
    "      '<td>'+g.cross+'</td>'+" +
    "      '<td>'+g.length+'</td>'+" +
    "      '<td><b>'+g.count+'</b></td>'+" +
    "      '<td>'+srcLens+'</td>'+" +
    "      '<td><b>'+nBins+'</b></td>'+" +
    "      '<td class=\"plan-col\" title=\"'+plan+'\">'+plan+'</td>'+" +
    "      '<td style=\"text-align:center\">'+ok+'</td>'+" +
    "    '</tr>';\n" +
    "    tbody.innerHTML+=tr;\n" +
    "  });\n" +
    "  document.getElementById('agg-stats').textContent=rows.length+' definicji';\n" +
    "}\n" +

    # updateOrderSummary — tylko wiersze per listwa, bez RAZEM
    "function updateOrderSummary(rows){\n" +
    "  var tbody=document.getElementById('order-body');\n" +
    "  tbody.innerHTML='';\n" +
    "  var lastCross=null;\n" +
    "  rows.forEach(function(r){\n" +
    "    if(lastCross!==null && r.cross!==lastCross){\n" +
    "      tbody.innerHTML+='<tr class=\"order-sep\"><td colspan=\"4\" style=\"padding:0;border:none;background:#f0f0f0;height:6px\"></td></tr>';\n" +
    "    }\n" +
    "    tbody.innerHTML+='<tr>'+" +
    "      '<td class=\"name-col\">'+r.cross+'</td>'+" +
    "      '<td>'+r.sl+'</td>'+" +
    "      '<td><b>'+r.count+'</b></td>'+" +
    "      '<td>'+r.mb+'</td>'+" +
    "    '</tr>';\n" +
    "    lastCross=r.cross;\n" +
    "  });\n" +
    "}\n" +

    # updateMbVolume — wypełnia tabele mb i kubatury
    "function updateMbVolume(rows){\n" +
    "  var tbodyMb=document.getElementById('mb-body');\n" +
    "  var tbodyVol=document.getElementById('vol-body');\n" +
    "  tbodyMb.innerHTML='';\n" +
    "  tbodyVol.innerHTML='';\n" +
    "  rows.forEach(function(r){\n" +
    "    tbodyMb.innerHTML+='<tr><td class=\"name-col\">'+r.cross+'</td><td>'+r.mb+'</td></tr>';\n" +
    "    tbodyVol.innerHTML+='<tr><td class=\"name-col\">'+r.cross+'</td><td>'+r.m3+'</td></tr>';\n" +
    "  });\n" +
    "}\n" +

    # sortTable
    "function sortTable(tableId,colIdx,isText){\n" +
    "  var table=document.getElementById(tableId);\n" +
    "  var tbody=table.tBodies[0];\n" +
    "  var rows=Array.from(tbody.rows);\n" +
    "  var ths=table.tHead.rows[0].cells;\n" +
    "  var th=ths[colIdx];\n" +
    "  var asc=!th.classList.contains('sorted-asc');\n" +
    "  Array.from(ths).forEach(function(h){h.classList.remove('sorted-asc','sorted-desc');});\n" +
    "  th.classList.add(asc?'sorted-asc':'sorted-desc');\n" +
    "  rows.sort(function(a,b){\n" +
    "    var av=a.cells[colIdx]?a.cells[colIdx].textContent.trim():'';\n" +
    "    var bv=b.cells[colIdx]?b.cells[colIdx].textContent.trim():'';\n" +
    "    if(!isText){var an=parseFloat(av),bn=parseFloat(bv);\n" +
    "      if(!isNaN(an)&&!isNaN(bn))return asc?an-bn:bn-an;}\n" +
    "    return asc?av.localeCompare(bv):bv.localeCompare(av);\n" +
    "  });\n" +
    "  rows.forEach(function(r){tbody.appendChild(r);});\n" +
    "}\n" +
    "</script>\n"
  end

  # ── Rejestracja menu ──────────────────────────────────────────────────────

  unless file_loaded?(__FILE__)
    UI.menu("Extensions").add_item("AutoCut & BOM") do
      AutoCut.run
    end
    file_loaded(__FILE__)
  end

end # module AutoCut
