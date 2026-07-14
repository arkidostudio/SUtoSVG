require_relative 'shadow'

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

      # Bake each shadow's per-receiver mask into its actual visible shape via
      # polygon subtraction — no SVG <mask>s needed, and every visible piece is
      # free to union with every other. Result: ONE path per layer.
      face_fills   = []
      shadow_polys_all = []
      shadow_fill_color = nil
      fills.each do |item|
        if item.is_a?(Hash)
          outers, holes = split_outers_and_holes(item[:polys])
          next if outers.empty?
          mask_outers, mask_gaps = split_mask_faces(item[:mask_faces] || [])
          cutters = holes + mask_outers
          visible = if cutters.empty? && mask_gaps.empty?
                      Shadow.union_polygons(outers)
                    else
                      Shadow.subtract_polygons(outers, cutters, mask_gaps)
                    end
          shadow_polys_all.concat(visible)
          shadow_fill_color ||= item[:polys].first.fill
        elsif visible?(item)
          face_fills << item
        end
      end

      # Ground shadow: subtract every object silhouette so it doesn't bleed
      # through the building; holes in those silhouettes act as light gaps.
      ground_outers, _ = split_outers_and_holes(shadow_polys)
      mask_outers, mask_gaps = split_mask_faces(ground_mask)
      ground_visible = if mask_outers.empty? && mask_gaps.empty?
                        Shadow.union_polygons(ground_outers)
                      else
                        Shadow.subtract_polygons(ground_outers, mask_outers, mask_gaps)
                      end
      unless ground_visible.empty? && shadow_lines.empty?
        out << %(  <g id="shadow-ground" inkscape:groupmode="layer" ) +
               %(inkscape:label="shadow-ground">)
        out << '    ' + loops_to_path_element(ground_visible, shadow_fill, dx, dy) unless ground_visible.empty?
        shadow_lines.each do |pts|
          out << '    ' + %(<polyline points="#{points_attr(pts, dx, dy)}" fill="none" ) +
                 %(stroke="#{shadow_fill}" stroke-width="1"/>)
        end
        out << '  </g>'
      end

      rendered = face_fills.map { |f| face_element(f, dx, dy) }
      unless shadow_polys_all.empty?
        rendered << loops_to_path_element(shadow_polys_all, shadow_fill_color || shadow_fill, dx, dy)
      end
      unless rendered.empty?
        out << layer_open(face_fills.empty? ? 'shadow-faces' : 'faces', nil)
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

    # A face is worth drawing if its outer loop encloses visible area.
    def visible?(face)
      outer = face.loops[0]
      !outer.nil? && outer.length >= 3 && signed_area(outer).abs >= MIN_AREA
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

    # Mask faces are Array of loops (loops[0] outer, rest holes). Outer loops
    # become subtractors (occluders); inner loops become light-gap re-adders.
    # Backward-compat: a plain flat loop (Array of [x, y]) is treated as an
    # outer-only silhouette with no holes.
    def split_mask_faces(mask_faces)
      outers = []
      gaps   = []
      mask_faces.each do |face|
        next if face.nil? || face.empty?
        # Detect: is `face` an Array-of-loops (multi-loop face) or a flat loop?
        loops = face.first.is_a?(Array) && face.first.first.is_a?(Numeric) ? [face] : face
        loops.each_with_index do |loop, i|
          next if loop.nil? || loop.length < 3 || signed_area(loop).abs < MIN_AREA
          (i.zero? ? outers : gaps) << loop
        end
      end
      [outers, gaps]
    end

    # Split a Face list into its outer loops (the shadow shapes) and its inner
    # loops (holes where light passes through). Both filtered by MIN_AREA.
    def split_outers_and_holes(faces)
      outers = []
      holes  = []
      faces.each do |f|
        (f.loops || []).each_with_index do |loop, i|
          next if loop.nil? || loop.length < 3 || signed_area(loop).abs < MIN_AREA
          (i.zero? ? outers : holes) << loop
        end
      end
      [outers, holes]
    end

    # Emit an array of boundary loops (outer CCW + hole CW) as ONE evenodd
    # path. Culls loops that shrunk below MIN_AREA after subtraction.
    def loops_to_path_element(loops, fill, dx, dy)
      loops = loops.select { |l| l.length >= 3 && signed_area(l).abs >= MIN_AREA }
      return nil if loops.empty?
      d = loops.map { |loop| loop_to_path(loop, dx, dy) }.join(' ')
      %(<path d="#{d}" fill-rule="evenodd" fill="#{fill}"/>)
    end

    # --- geometry helpers --------------------------------------------------

    # Emit one <defs> block of grayscale <mask>s. Each is a white bbox rect with
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
