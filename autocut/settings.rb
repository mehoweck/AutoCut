# autocut/settings.rb
# Persistent user preferences stored via SketchUp's built-in key-value store.

module AutoCut
  module Settings
    def self.source_lengths_str
      Sketchup.read_default(AutoCut::PREF_KEY, 'source_lengths', '200').to_s
    end

    def self.cut_loss
      Sketchup.read_default(AutoCut::PREF_KEY, 'cut_loss', 0.4).to_f
    end

    def self.use_brute_force
      Sketchup.read_default(AutoCut::PREF_KEY, 'use_bf', false)
    end

    def self.save(lengths_str, cut_loss_val, use_bf)
      Sketchup.write_default(AutoCut::PREF_KEY, 'source_lengths', lengths_str.to_s)
      Sketchup.write_default(AutoCut::PREF_KEY, 'cut_loss',       cut_loss_val.to_f)
      Sketchup.write_default(AutoCut::PREF_KEY, 'use_bf',         use_bf)
    end

    def self.parse_lengths(str)
      str.to_s.split(',').map { |s| s.strip.to_f }.select { |v| v > 0 }.sort.uniq
    end
  end
end
