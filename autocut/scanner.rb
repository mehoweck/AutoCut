# autocut/scanner.rb
# Traverses the SketchUp model (or a selected group) and extracts raw instance data
# for every ComponentInstance whose name matches the cross-section naming convention.

module AutoCut
  module Scanner
    def self.scan_scope(model)
      sel = model.selection
      if !sel.empty? && sel.first.is_a?(Sketchup::Group)
        label = sel.first.name.empty? ? '(unnamed)' : sel.first.name
        ["selected group: \"#{label}\"", sel.first.entities]
      else
        ['entire model', model.entities]
      end
    end

    def self.collect(entities)
      result = []
      collect_recursive(entities, result)
      result
    end

    class << self
      private

      def collect_recursive(entities, result)
        entities.each do |entity|
          if entity.is_a?(Sketchup::ComponentInstance)
            result << extract_instance_data(entity) if entity.definition.name =~ AutoCut::NAME_REGEX
            collect_recursive(entity.definition.entities, result)
          elsif entity.is_a?(Sketchup::Group)
            collect_recursive(entity.entities, result)
          end
        end
      end

      def extract_instance_data(instance)
        name  = instance.definition.name
        m     = name.match(/^(\d+)x(\d+)/)
        dim_a = m ? m[1].to_f : nil
        dim_b = m ? m[2].to_f : nil

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

        {
          name:      name,
          dim_a:     dim_a,
          dim_b:     dim_b,
          dim_w:     dims_mm[0],
          dim_h:     dims_mm[1],
          dim_d:     dims_mm[2],
          length_mm: extract_length(dims_mm, dim_a, dim_b),
          rot_x:     (Math.atan2(-ta[2], Math.sqrt(ta[6]**2 + ta[10]**2)) * 180.0 / Math::PI).round(2),
          rot_y:     (Math.atan2(ta[8],  ta[10]) * 180.0 / Math::PI).round(2),
          rot_z:     (Math.atan2(ta[1],  ta[0])  * 180.0 / Math::PI).round(2),
          valid:     validate_dims(dims_mm, dim_a, dim_b)
        }
      end

      # Returns the longest dimension that does not match either cross-section side.
      # Falls back to the absolute longest dimension when no such axis exists.
      def extract_length(dims_mm, dim_a, dim_b)
        sorted = dims_mm.sort.reverse
        return sorted[0] unless dim_a && dim_b
        cross = [dim_a, dim_b].sort
        found = sorted.find { |d| !cross.any? { |c| (d - c).abs <= AutoCut::TOLERANCE_MM } }
        (found || sorted[0]).round(2)
      end

      def validate_dims(dims_mm, dim_a, dim_b)
        return true unless dim_a && dim_b
        [dim_a, dim_b].all? { |c| dims_mm.any? { |d| (d - c).abs <= AutoCut::TOLERANCE_MM } }
      end
    end
  end
end
