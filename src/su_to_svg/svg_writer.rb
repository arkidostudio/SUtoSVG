# SUtoSVG — SVG document builder.
#
# Pure Ruby, NO SketchUp dependency, so it can be unit-tested with a plain
# `ruby` interpreter. It takes already-projected 2D geometry (screen pixels),
# normalizes it to a bounding box, and emits a well-formed SVG string.
#
# Edges are split into named, selectable layer groups by weight class (thin,
# medium, thick), drawn thin -> thick so heavier lines sit on top. The groups
# carry Inkscape layer attributes so vector editors expose them as layers.
#
# Data contract:
#   Face.loops  : Array of loops. loops[0] is the OUTER loop; loops[1..] holes.
#                 Each loop is an Array of [x, y] pairs (floats, screen pixels).
#   Face.fill   : "#rrggbb" string.
#   Edge.points : Array of [x, y] pairs (a polyline).
#   Edge.width  : stroke width in px.
#   Edge.layer  : layer key (:thin/:medium/:thick), or nil for a single group.

module SUtoSVG
  module SvgWriter
    Face = Struct.new(:loops, :fill)
    Edge = Struct.new(:points, :width, :layer)

    # Draw order (and layer stacking): earlier = underneath.
    LAYER_ORDER = %i[thin medium thick].freeze

    module_function

    # fills         : Array, drawn back-to-front, of EITHER a Face OR a clipped
    #                 shadow group { clip: [[x,y]...], polys: [Face...] } (a
    #                 shadow cast onto a receiving face, clipped to it). Mixing
    #                 the two lets cast shadows occlude correctly by depth.
    # edges         : Array<Edge>.
    # shadow_polys  : Array<Face> — ground shadow areas (own layer, at bottom).
    # shadow_lines  : Array of [[x,y],[x,y]] — shadow outlines (LINES-type).
    # margin        : uniform padding (px) added around the content bounds.
    def build(fills, edges, shadow_polys: [], shadow_lines: [],
              shadow_fill: '#808080', shadow_opacity: 0.5, margin: 0.0)
      min_x, min_y, max_x, max_y = bounds(fills, edges, shadow_polys, shadow_lines)
      return empty_svg if min_x.nil? # nothing to draw

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

      out.concat(clip_defs(fills, dx, dy))

      # Ground shadows go at the bottom, in their own selectable layer.
      unless shadow_polys.empty? && shadow_lines.empty?
        out << %(  <g id="shadows" inkscape:groupmode="layer" inkscape:label="shadows" ) +
               %(opacity="#{fmt(shadow_opacity)}">)
        shadow_polys.each { |f| out << '    ' + face_element(f, dx, dy) }
        shadow_lines.each do |pts|
          out << '    ' + %(<polyline points="#{points_attr(pts, dx, dy)}" fill="none" ) +
                 %(stroke="#{shadow_fill}" stroke-width="1"/>)
        end
        out << '  </g>'
      end

      # Faces and cast-shadow groups, depth-ordered together.
      unless fills.empty?
        out << layer_open('faces', nil)
        clip_i = 0
        fills.each do |item|
          if item.is_a?(Hash) # clipped cast-shadow group
            out << %(    <g clip-path="url(#sfclip#{clip_i})">)
            item[:polys].each { |f| out << '      ' + face_element(f, dx, dy) }
            out << '    </g>'
            clip_i += 1
          else
            out << '    ' + face_element(item, dx, dy)
          end
        end
        out << '  </g>'
      end

      grouped = edges.group_by { |e| e.layer }
      layer_keys = LAYER_ORDER + (grouped.keys - LAYER_ORDER) # known order first
      layer_keys.each do |key|
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
        pts = points_attr(loops[0] || [], dx, dy)
        %(<polygon points="#{pts}" fill="#{face.fill}"/>)
      else
        d = loops.map { |loop| loop_to_path(loop, dx, dy) }.join(' ')
        %(<path d="#{d}" fill-rule="evenodd" fill="#{face.fill}"/>)
      end
    end

    def edge_element(edge, dx, dy)
      %(<polyline points="#{points_attr(edge.points, dx, dy)}"/>)
    end

    # --- geometry helpers --------------------------------------------------

    # <clipPath> definitions for every clipped cast-shadow group in `fills`,
    # numbered in the same order they are drawn.
    def clip_defs(fills, dx, dy)
      groups = fills.select { |x| x.is_a?(Hash) }
      return [] if groups.empty?
      lines = ['  <defs>']
      groups.each_with_index do |g, i|
        lines << %(    <clipPath id="sfclip#{i}"><polygon points="#{points_attr(g[:clip], dx, dy)}"/></clipPath>)
      end
      lines << '  </defs>'
      lines
    end

    # Returns [min_x, min_y, max_x, max_y], or all-nil if there are no points.
    # Cast-shadow polys are clipped to their receiving face, so only the clip
    # loop contributes to the canvas bounds (not the unclipped projection).
    def bounds(fills, edges, shadow_polys = [], shadow_lines = [])
      min_x = min_y = max_x = max_y = nil
      visit = lambda do |x, y|
        min_x = x if min_x.nil? || x < min_x
        min_y = y if min_y.nil? || y < min_y
        max_x = x if max_x.nil? || x > max_x
        max_y = y if max_y.nil? || y > max_y
      end
      fills.each do |item|
        if item.is_a?(Hash)
          item[:clip].each { |(x, y)| visit.call(x, y) }
        else
          item.loops.each { |loop| loop.each { |(x, y)| visit.call(x, y) } }
        end
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

    # Compact number formatting: 2 decimals, trailing zeros stripped.
    def fmt(n)
      s = format('%.2f', n.to_f)
      s = s.sub(/\.?0+$/, '') if s.include?('.')
      s
    end
  end
end
