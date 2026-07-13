# SUtoSVG — SVG document builder.
#
# Pure Ruby, NO SketchUp dependency, so it can be unit-tested with a plain
# `ruby` interpreter. It takes already-projected 2D geometry (screen pixels),
# normalizes it to a bounding box, and emits a well-formed SVG string.
#
# The ground shadow is its own layer (pieces merged into one shape). Object
# faces and cast-onto-face shadows are drawn as ONE depth-ordered list (`fills`,
# a mix of Face and clipped shadow groups) so a nearer object correctly hides a
# shadow on a farther face. Edges are split into per-weight layers on top.
#
# Data contract:
#   Face.loops  : Array of loops. loops[0] outer; loops[1..] holes. Each loop is
#                 an Array of [x, y] pairs (floats, screen pixels).
#   Face.fill   : "#rrggbb" string.
#   Edge.points : Array of [x, y] pairs (a polyline).
#   Edge.width  : stroke width in px.
#   Edge.layer  : layer key (:thin/:medium/:thick), or nil.
#   fills item  : a Face, OR { polys: [Face...] } (a shadow cast onto a
#                 receiving face, already clipped to it; merged into one path).

module SUtoSVG
  module SvgWriter
    Face = Struct.new(:loops, :fill)
    Edge = Struct.new(:points, :width, :layer)

    LAYER_ORDER = %i[thin medium thick].freeze

    # Shapes with less area than this (px²) are invisible — e.g. faces seen
    # edge-on in a straight-on view collapse to zero-area lines. They are culled
    # so the export contains only real, visible shapes.
    MIN_AREA = 0.5

    module_function

    # fills        : Array of Face | { polys:, mask_loops: } (back-to-front). A
    #                Hash item is a shadow cast onto a receiving face; its
    #                `mask_loops` are 2D outer loops of strictly-nearer faces
    #                that must be knocked out (partial-occlusion HLR).
    # edges        : Array<Edge>.
    # shadow_polys : Array<Face> — the ground shadow (merged into one shape).
    # shadow_lines : Array of [[x,y],[x,y]] — ground shadow outlines (LINES-type).
    # ground_mask  : Array of 2D outer loops — every object silhouette. Used to
    #                clip the ground shadow so it doesn't bleed through objects.
    def build(fills, edges, shadow_polys: [], shadow_lines: [], shadow_fill: '#808080',
              shadow_opacity: 0.5, margin: 0.0, ground_mask: [])
      min_x, min_y, max_x, max_y = bounds(fills, edges, shadow_polys, shadow_lines)
      return empty_svg if min_x.nil?

      dx = margin - min_x
      dy = margin - min_y
      width  = (max_x - min_x) + 2 * margin
      height = (max_y - min_y) + 2 * margin

      out = []
      out << %(<?xml version="1.0" encoding="UTF-8" standalone="no"?>)
      out << %(<svg xmlns="http://www.w3.org/2000/svg" ) +
             %(xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" ) +
             %(width="#{fmt(width)}" height="#{fmt(height)}" ) +
             %(viewBox="0 0 #{fmt(width)} #{fmt(height)}">)

      up = merged_shape(shadow_polys, dx, dy)

      # Emit one <mask> per shadow that needs partial-occlusion masking: the
      # ground shadow (masked by every object silhouette) plus each cast shadow
      # (masked by strictly-nearer face silhouettes). Using <mask> instead of
      # <clipPath> so overlapping silhouettes union in raster space — clipPath
      # + evenodd would toggle overlaps back to "inside" and leak the shadow.
      mask_specs = []
      mask_specs << { id: 'mask-ground', loops: ground_mask } if up && ground_mask.any?
      fills.each_with_index do |item, i|
        next unless item.is_a?(Hash) && item[:mask_loops] && !item[:mask_loops].empty?
        mask_specs << { id: "mask-fs-#{i}", loops: item[:mask_loops] }
      end
      out.concat(mask_defs(mask_specs, dx, dy, width, height))

      # Ground shadow (own group, pieces merged into one shape). Zero-area
      # content (shadow seen edge-on) is culled; an empty layer is omitted.
      # NOTE: shadow tone is baked into the fill color via `blended_shadow_gray`,
      # so NO layer-level opacity here (that would double-blend and lighten it).
      unless up.nil? && shadow_lines.empty?
        out << %(  <g id="shadow-ground" inkscape:groupmode="layer" ) +
               %(inkscape:label="shadow-ground">)
        up = merged_shape(shadow_polys, dx, dy, mask_id: 'mask-ground') if up && ground_mask.any?
        out << '    ' + up if up
        shadow_lines.each do |pts|
          out << '    ' + %(<polyline points="#{points_attr(pts, dx, dy)}" fill="none" ) +
                 %(stroke="#{shadow_fill}" stroke-width="1"/>)
        end
        out << '  </g>'
      end

      # Object faces + cast-onto-face shadows, depth-ordered together so they
      # occlude correctly. Cast shadows arrive pre-clipped to their receiving
      # face, so each draws as a plain merged shape — no clipPath masks.
      # Edge-on (zero-area) faces and shadows are culled.
      rendered = []
      any_face = false
      fills.each_with_index do |item, i|
        if item.is_a?(Hash)
          mask_id = (item[:mask_loops] && !item[:mask_loops].empty?) ? "mask-fs-#{i}" : nil
          cp = merged_shape(item[:polys], dx, dy, mask_id: mask_id)
          rendered << cp if cp
        elsif visible?(item)
          rendered << face_element(item, dx, dy)
          any_face = true
        end
      end
      unless rendered.empty?
        layer_id = any_face ? 'faces' : 'shadow-faces'
        out << layer_open(layer_id, nil)
        rendered.each { |el| out << '    ' + el }
        out << '  </g>'
      end

      grouped = edges.group_by { |e| e.layer }
      (LAYER_ORDER + (grouped.keys - LAYER_ORDER)).each do |key|
        es = grouped[key]
        next if es.nil? || es.empty?
        out << layer_open("edges-#{key || 'all'}", es.first.width)
        es.each { |e| out << '    ' + edge_element(e, dx, dy) }
        out << '  </g>'
      end

      out << '</svg>'
      out.join("\n") + "\n"
    end

    # --- element builders --------------------------------------------------

    def layer_open(name, stroke_width)
      attrs = %(id="#{name}" inkscape:groupmode="layer" inkscape:label="#{name}")
      if stroke_width
        attrs += %( stroke="#000000" fill="none" ) +
                 %(stroke-linecap="round" stroke-linejoin="round" ) +
                 %(stroke-width="#{fmt(stroke_width)}")
      end
      "  <g #{attrs}>"
    end

    def face_element(face, dx, dy)
      loops = face.loops
      if loops.length <= 1
        %(<polygon points="#{points_attr(loops[0] || [], dx, dy)}" fill="#{face.fill}"/>)
      else
        d = loops.map { |loop| loop_to_path(loop, dx, dy) }.join(' ')
        %(<path d="#{d}" fill-rule="evenodd" fill="#{face.fill}"/>)
      end
    end

    def edge_element(edge, dx, dy)
      %(<polyline points="#{points_attr(edge.points, dx, dy)}"/>)
    end

    # One shape for a shadow. A single face is a true (pre-computed) union — draw
    # it directly, honouring holes via evenodd. Several faces are raw overlapping
    # pieces — merge them with a nonzero compound path (the fallback).
    # Zero-area (edge-on) content is culled; returns nil if nothing visible.
    def merged_shape(faces, dx, dy, mask_id: nil)
      faces = faces.select { |f| visible?(f) }
      return nil if faces.empty?
      el = faces.length == 1 ? face_element(faces.first, dx, dy) : union_path(faces, dx, dy)
      return nil if el.nil?
      mask_id ? el.sub(/<(polygon|path) /, %(<\\1 mask="url(##{mask_id})" )) : el
    end

    # Merge many (overlapping) polygons into ONE <path>: each outer loop becomes
    # a subpath, all wound the same way, filled nonzero so the result is their
    # union — contiguous pieces read as one shape, no internal seams. Degenerate
    # (zero-area) loops are dropped; exact duplicate loops collapse to one.
    def union_path(faces, dx, dy)
      loops = faces.map { |f| normalize_winding(f.loops[0] || []) }
                   .select { |l| l.length >= 3 && signed_area(l).abs >= MIN_AREA }
      loops = loops.uniq { |l| l.map { |(x, y)| [x.round(2), y.round(2)] }.sort }
      return nil if loops.empty?
      d = loops.map { |loop| loop_to_path(loop, dx, dy) }.join(' ')
      %(<path d="#{d}" fill-rule="nonzero" fill="#{faces.first.fill}"/>)
    end

    # A face is worth drawing if its outer loop encloses visible area.
    def visible?(face)
      outer = face.loops[0]
      !outer.nil? && outer.length >= 3 && signed_area(outer).abs >= MIN_AREA
    end

    def normalize_winding(loop)
      signed_area(loop).negative? ? loop.reverse : loop
    end

    def signed_area(loop)
      s = 0.0
      n = loop.length
      n.times do |i|
        ax, ay = loop[i]
        bx, by = loop[(i + 1) % n]
        s += ax * by - bx * ay
      end
      s * 0.5
    end

    # --- geometry helpers --------------------------------------------------

    # Emit one <defs> block of grayscale <mask>s. Each mask is a white bbox rect
    # with black silhouette paths painted on top; the shadow shows through where
    # the mask is white. Raster black-on-black unions cleanly, so overlapping
    # silhouettes just work — no polygon boolean needed.
    def mask_defs(specs, dx, dy, width, height)
      valid = specs.select { |s| s[:loops] && !s[:loops].empty? }
      return [] if valid.empty?
      lines = ['  <defs>']
      valid.each do |spec|
        lines << %(    <mask id="#{spec[:id]}" maskUnits="userSpaceOnUse">)
        lines << %(      <rect width="#{fmt(width)}" height="#{fmt(height)}" fill="white"/>)
        spec[:loops].each do |loop|
          lines << %(      <path d="#{loop_to_path(loop, dx, dy)}" fill="black"/>)
        end
        lines << '    </mask>'
      end
      lines << '  </defs>'
      lines
    end

    # Returns [min_x, min_y, max_x, max_y], or all-nil if there are no points.
    def bounds(fills, edges, shadow_polys = [], shadow_lines = [])
      min_x = min_y = max_x = max_y = nil
      visit = lambda do |x, y|
        min_x = x if min_x.nil? || x < min_x
        min_y = y if min_y.nil? || y < min_y
        max_x = x if max_x.nil? || x > max_x
        max_y = y if max_y.nil? || y > max_y
      end
      fills.each do |item|
        faces = item.is_a?(Hash) ? item[:polys] : [item]
        faces.each { |f| f.loops.each { |loop| loop.each { |(x, y)| visit.call(x, y) } } }
      end
      shadow_polys.each { |f| f.loops.each { |loop| loop.each { |(x, y)| visit.call(x, y) } } }
      edges.each { |e| e.points.each { |(x, y)| visit.call(x, y) } }
      shadow_lines.each { |pts| pts.each { |(x, y)| visit.call(x, y) } }
      [min_x, min_y, max_x, max_y]
    end

    def points_attr(loop, dx, dy)
      loop.map { |(x, y)| "#{fmt(x + dx)},#{fmt(y + dy)}" }.join(' ')
    end

    def loop_to_path(loop, dx, dy)
      return '' if loop.empty?
      cmds = loop.each_with_index.map do |(x, y), i|
        "#{i.zero? ? 'M' : 'L'}#{fmt(x + dx)},#{fmt(y + dy)}"
      end
      cmds.join(' ') + ' Z'
    end

    def empty_svg
      %(<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n) +
        %(<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1" viewBox="0 0 1 1"/>\n)
    end

    def fmt(n)
      s = format('%.2f', n.to_f)
      s = s.sub(/\.?0+$/, '') if s.include?('.')
      s
    end
  end
end
