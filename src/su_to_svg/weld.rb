# SUtoSVG — joint weld (gap closing).
#
# Pure Ruby, NO SketchUp dependency. A post-process over the final 2D edge
# segments: hidden-line removal can shave a few pixels off an edge tip right
# where it meets a joint, leaving a small visible gap. This extends each
# "dangling" endpoint ALONG ITS OWN DIRECTION until it meets a nearby line
# (within a small pixel threshold). Because an endpoint only ever moves along
# its own edge's axis, this can't invent sideways/spurious connections.

module SUtoSVG
  module Weld
    DANGLE_EPS = 0.8    # an endpoint within this of another line isn't dangling
    BACK_EPS   = 0.5    # allow a tiny backward snap (target just behind the tip)

    module_function

    # edges     : Array responding to #points -> [[x,y], ...] (mutated in place).
    # threshold : max pixels an endpoint may be extended to close a gap.
    # Returns the same edges.
    def close_gaps(edges, threshold: 12.0)
      segs = edges.map(&:points)
      moves = []
      segs.each_with_index do |pts, i|
        next if pts.length < 2
        endpoints(pts).each do |ei, ai|
          tip = pts[ei]
          nbr = pts[ai]
          next unless dangling?(tip, segs, i)
          dir = unit(tip[0] - nbr[0], tip[1] - nbr[1])
          next unless dir
          target = nearest_extension(tip, dir, segs, i, threshold)
          moves << [pts, ei, target] if target
        end
      end
      moves.each { |pts, ei, target| pts[ei] = target }
      edges
    end

    # The two endpoints of a polyline, each as [tip_index, neighbour_index].
    def endpoints(pts)
      last = pts.length - 1
      last.zero? ? [[0, 1]] : [[0, 1], [last, last - 1]]
    end

    # True if `p` touches no OTHER edge (so it's a loose tip, not a real vertex).
    def dangling?(p, segs, owner)
      segs.each_with_index do |pts, j|
        next if j == owner
        pts.each_cons(2) { |a, b| return false if point_segment_dist(p, a, b) < DANGLE_EPS }
      end
      true
    end

    # Extend the ray (origin `o`, unit `dir`) to the nearest other segment it
    # crosses within `threshold`; returns that point or nil.
    def nearest_extension(o, dir, segs, owner, threshold)
      best_u = nil
      best_pt = nil
      segs.each_with_index do |pts, j|
        next if j == owner
        pts.each_cons(2) do |p, q|
          hit = ray_segment(o, dir, p, q)
          next unless hit
          u, pt = hit
          next if u > threshold || u < -BACK_EPS
          if best_u.nil? || u < best_u
            best_u = u
            best_pt = pt
          end
        end
      end
      best_pt
    end

    # --- geometry helpers ----------------------------------------------------

    def unit(dx, dy)
      len = Math.hypot(dx, dy)
      len < 1e-9 ? nil : [dx / len, dy / len]
    end

    # Ray o + u*dir (u>=~0) vs segment p->q. Returns [u, point] or nil.
    def ray_segment(o, dir, p, q)
      rx, ry = dir
      sx = q[0] - p[0]
      sy = q[1] - p[1]
      den = rx * sy - ry * sx
      return nil if den.abs < 1e-9 # parallel
      ox = p[0] - o[0]
      oy = p[1] - o[1]
      u = (ox * sy - oy * sx) / den # distance along the (unit) ray
      v = (ox * ry - oy * rx) / den # 0..1 along the target segment
      return nil unless v >= -0.06 && v <= 1.06
      [u, [o[0] + rx * u, o[1] + ry * u]]
    end

    def point_segment_dist(pt, a, b)
      abx = b[0] - a[0]
      aby = b[1] - a[1]
      l2 = (abx * abx + aby * aby).to_f
      return Math.hypot(pt[0] - a[0], pt[1] - a[1]) if l2 < 1e-9
      t = ((pt[0] - a[0]) * abx + (pt[1] - a[1]) * aby) / l2
      t = 0.0 if t < 0.0
      t = 1.0 if t > 1.0
      Math.hypot(pt[0] - (a[0] + t * abx), pt[1] - (a[1] + t * aby))
    end
  end
end
