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

    # faces : Array<Face>, already sorted back-to-front (drawn in order).
    # edges : Array<Edge>.
    # margin: uniform padding (px) added around the content bounds.
    def build(faces, edges, margin: 0.0)
      min_x, min_y, max_x, max_y = bounds(faces, edges)
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

      unless faces.empty?
        out << layer_open('faces', nil)
        faces.each { |f| out << '    ' + face_element(f, dx, dy) }
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

    # Returns [min_x, min_y, max_x, max_y], or all-nil if there are no points.
    def bounds(faces, edges)
      min_x = min_y = max_x = max_y = nil
      visit = lambda do |x, y|
        min_x = x if min_x.nil? || x < min_x
        min_y = y if min_y.nil? || y < min_y
        max_x = x if max_x.nil? || x > max_x
        max_y = y if max_y.nil? || y > max_y
      end
      faces.each { |f| f.loops.each { |loop| loop.each { |(x, y)| visit.call(x, y) } } }
      edges.each { |e| e.points.each { |(x, y)| visit.call(x, y) } }
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
