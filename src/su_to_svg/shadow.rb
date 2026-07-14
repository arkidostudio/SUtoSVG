# SUtoSVG — cast-shadow projection (clean-room; no third-party code).
#
# Pure Ruby, NO SketchUp dependency, so the projection math is unit-testable.
# The standard planar-shadow technique: cast each 3D point along the light
# direction until it meets a horizontal receiving plane (z = ground). The union
# of every projected face is the object's shadow silhouette on that plane.

module SUtoSVG
  module Shadow
    module_function

    # Project point p = [x,y,z] along light direction dir = [dx,dy,dz] onto the
    # horizontal plane z = ground. Returns [x,y,ground], or nil when the ray is
    # parallel to the plane or the point is on the far side (t < 0) so it can't
    # cast onto the plane.
    def project_to_ground(p, dir, ground)
      dz = dir[2].to_f
      return nil if dz.abs < 1e-9
      t = (ground - p[2]) / dz
      return nil if t < -1e-9 # point below the plane relative to the light
      [p[0] + dir[0] * t, p[1] + dir[1] * t, ground]
    end

    # Project a loop (Array of [x,y,z]) to the ground. Returns the projected loop
    # or nil if any vertex can't be projected (so the caller drops the polygon).
    def project_loop(loop, dir, ground)
      project_loop_to_plane(loop, dir, [0, 0, ground], [0, 0, 1])
    end

    # Project point p along dir onto the plane through plane_pt with normal
    # plane_n. Returns [x,y,z], or nil if parallel or on the far (t<0) side.
    def project_to_plane(p, dir, plane_pt, plane_n)
      denom = plane_n[0] * dir[0] + plane_n[1] * dir[1] + plane_n[2] * dir[2]
      return nil if denom.abs < 1e-9
      wx = plane_pt[0] - p[0]
      wy = plane_pt[1] - p[1]
      wz = plane_pt[2] - p[2]
      t = (plane_n[0] * wx + plane_n[1] * wy + plane_n[2] * wz) / denom
      return nil if t < -1e-9 # caster is on the far side of the plane from the sun
      [p[0] + dir[0] * t, p[1] + dir[1] * t, p[2] + dir[2] * t]
    end

    def project_loop_to_plane(loop, dir, plane_pt, plane_n)
      out = []
      loop.each do |p|
        r = project_to_plane(p, dir, plane_pt, plane_n)
        return nil if r.nil?
        out << r
      end
      out
    end

    # Clip a 3D polygon to the half-space in front of a plane (keep the part
    # where plane_n·(p - plane_pt) >= 0). Sutherland-Hodgman against one plane;
    # used to trim a caster to the sun side of a receiver before projecting, so
    # casters that straddle the plane (common for vertical receivers) still work.
    def clip_to_halfspace(loop, plane_pt, plane_n)
      out = []
      m = loop.length
      m.times do |i|
        a = loop[i]
        b = loop[(i + 1) % m]
        da = side(a, plane_pt, plane_n)
        db = side(b, plane_pt, plane_n)
        out << a if da >= 0
        if (da >= 0) != (db >= 0) # edge crosses the plane -> add intersection
          t = da.to_f / (da - db)
          out << [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
        end
      end
      out
    end

    def side(p, plane_pt, plane_n)
      plane_n[0] * (p[0] - plane_pt[0]) + plane_n[1] * (p[1] - plane_pt[1]) +
        plane_n[2] * (p[2] - plane_pt[2])
    end

    # --- 2D polygon clipping (Sutherland-Hodgman) ---------------------------

    # Clip 2D polygon `subject` to CONVEX 2D polygon `clip` (both Arrays of
    # [x, y]). Returns the clipped polygon ([] if no overlap). Used to bake a
    # cast shadow down to its receiving face at export time, so the SVG gets a
    # plain pre-trimmed shape instead of a clipPath mask.
    def clip_polygon(subject, clip)
      return [] if subject.length < 3 || clip.length < 3
      clip = clip.reverse if signed_area2d(clip) < 0 # normalize orientation
      out = subject
      m = clip.length
      m.times do |i|
        out = clip_against_edge2d(out, clip[i], clip[(i + 1) % m])
        return [] if out.length < 3
      end
      out
    end

    # Keep the part of `poly` on the interior side of directed edge a->b
    # (interior = left side for a positively-oriented clip polygon).
    def clip_against_edge2d(poly, a, b)
      out = []
      n = poly.length
      n.times do |i|
        p = poly[i]
        q = poly[(i + 1) % n]
        dp = cross2d(a, b, p)
        dq = cross2d(a, b, q)
        out << p if dp >= 0
        if (dp >= 0) != (dq >= 0)
          t = dp.to_f / (dp - dq)
          out << [p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t]
        end
      end
      out
    end

    def cross2d(a, b, p)
      (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
    end

    def signed_area2d(loop)
      s = 0.0
      n = loop.length
      n.times do |i|
        ax, ay = loop[i]
        bx, by = loop[(i + 1) % n]
        s += ax * by - bx * ay
      end
      s * 0.5
    end

    # --- 2D polygon boolean union ------------------------------------------

    # Union an array of simple 2D polygons (each [[x,y], ...]) into an array of
    # boundary loops. Outer loops CCW, holes CW — the caller can emit them as
    # one compound path with fill-rule="evenodd". Handles overlapping/adjacent
    # polygons; degenerate/empty input returns [].
    #
    # Algorithm: split every edge at every crossing with edges of OTHER polys,
    # keep sub-edges whose exterior-side midpoint isn't inside any polygon,
    # then walk the kept sub-edges into closed loops. Pairwise O(n²) — fine for
    # the ~hundreds of shadow edges we produce per export.
    def union_polygons(polys)
      polys = polys.select { |p| p.length >= 3 && signed_area2d(p).abs > 1e-9 }
                   .map { |p| signed_area2d(p) >= 0 ? p : p.reverse }
      return [] if polys.empty?

      edges = []
      polys.each_with_index do |poly, pi|
        poly.each_index { |i| edges << [poly[i], poly[(i + 1) % poly.length], pi] }
      end

      splits = Array.new(edges.length) { [] }
      edges.each_with_index do |e1, i|
        ((i + 1)...edges.length).each do |j|
          e2 = edges[j]
          next if e1[2] == e2[2]
          pt = seg_intersect(e1[0], e1[1], e2[0], e2[1])
          next unless pt
          splits[i] << pt
          splits[j] << pt
        end
      end

      # T-junctions: when a vertex of one polygon sits on the interior of
      # another polygon's edge (a very common case in projected step shadows),
      # split that edge there. Without this, partially-coincident boundaries
      # both survive the boundary filter → duplicate edges → spurious loops.
      polys.each_with_index do |poly, pi|
        poly.each do |v|
          edges.each_with_index do |(a, b, pj), i|
            next if pj == pi
            dx = b[0] - a[0]; dy = b[1] - a[1]
            len2 = dx * dx + dy * dy
            next if len2 < 1e-9
            t = ((v[0] - a[0]) * dx + (v[1] - a[1]) * dy).to_f / len2
            next if t < 1e-6 || t > 1 - 1e-6
            px = a[0] + t * dx; py = a[1] + t * dy
            next if (v[0] - px)**2 + (v[1] - py)**2 > 1e-6
            splits[i] << [px, py]
          end
        end
      end

      segs = []
      edges.each_with_index do |(a, b, pi), i|
        dx = b[0] - a[0]; dy = b[1] - a[1]
        pts = [a, *splits[i], b]
              .uniq { |p| [p[0].round(6), p[1].round(6)] }
              .sort_by { |p| (p[0] - a[0]) * dx + (p[1] - a[1]) * dy }
        pts.each_cons(2) do |p, q|
          next if (p[0] - q[0]).abs < 1e-9 && (p[1] - q[1]).abs < 1e-9
          segs << [p, q, pi]
        end
      end

      # Keep sub-segments on the union boundary: exterior midpoint (right side
      # for a CCW polygon) must NOT lie inside any other polygon.
      kept = segs.select do |a, b, pi|
        mx = (a[0] + b[0]) * 0.5; my = (a[1] + b[1]) * 0.5
        dx = b[0] - a[0]; dy = b[1] - a[1]
        len = Math.sqrt(dx * dx + dy * dy)
        next false if len < 1e-9
        eps = 1e-4
        nx =  dy / len; ny = -dx / len
        px = mx + nx * eps; py = my + ny * eps
        polys.each_with_index.none? { |p, k| k != pi && point_in_polygon2d?(px, py, p) }
      end

      # Coincident boundary segments (shared edge of touching / duplicated
      # polygons) all survive the filter — collapse both same-direction and
      # reverse duplicates down to one.
      seen = {}
      kept = kept.reject do |a, b, _|
        key = [a[0].round(4), a[1].round(4), b[0].round(4), b[1].round(4)]
        rev = [b[0].round(4), b[1].round(4), a[0].round(4), a[1].round(4)]
        if seen[key] || seen[rev]
          true
        else
          seen[key] = true
          false
        end
      end

      walk_loops2d(kept)
    end

    # Line-segment intersection (open — endpoints on either segment don't
    # count). Returns [x,y] or nil.
    def seg_intersect(p1, p2, p3, p4)
      x1, y1 = p1; x2, y2 = p2; x3, y3 = p3; x4, y4 = p4
      denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
      return nil if denom.abs < 1e-12
      t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)).to_f / denom
      u = ((x1 - x3) * (y1 - y2) - (y1 - y3) * (x1 - x2)).to_f / denom
      return nil if t < 1e-9 || t > 1 - 1e-9 || u < 1e-9 || u > 1 - 1e-9
      [x1 + t * (x2 - x1), y1 + t * (y2 - y1)]
    end

    # Standard ray-cast point-in-polygon.
    def point_in_polygon2d?(x, y, poly)
      inside = false
      n = poly.length
      j = n - 1
      n.times do |i|
        xi, yi = poly[i]; xj, yj = poly[j]
        if ((yi > y) != (yj > y)) &&
           (x < (xj - xi) * (y - yi).to_f / (yj - yi) + xi)
          inside = !inside
        end
        j = i
      end
      inside
    end

    # Walk directed sub-segments into closed loops. At a junction pick the
    # sharpest LEFT turn — that keeps the union's interior on the walker's
    # left throughout, producing the outer boundary + any hole loops.
    def walk_loops2d(segs)
      return [] if segs.empty?
      round = ->(p) { [p[0].round(4), p[1].round(4)] }
      by_start = Hash.new { |h, k| h[k] = [] }
      segs.each { |seg| by_start[round.call(seg[0])] << seg }

      used = {}
      loops = []
      segs.each do |start_seg|
        next if used[start_seg]
        loop_pts = []
        cur = start_seg
        limit = segs.length + 1
        while cur && !used[cur] && limit > 0
          used[cur] = true
          loop_pts << cur[0]
          limit -= 1
          key = round.call(cur[1])
          break if key == round.call(start_seg[0]) && loop_pts.length >= 3
          candidates = by_start[key].reject { |s| used[s] }
          break if candidates.empty?
          if candidates.length == 1
            cur = candidates[0]
          else
            in_dir = Math.atan2(cur[1][1] - cur[0][1], cur[1][0] - cur[0][0])
            cur = candidates.max_by do |c|
              out_dir = Math.atan2(c[1][1] - c[0][1], c[1][0] - c[0][0])
              (out_dir - in_dir) % (2 * Math::PI) # largest CCW turn = sharpest left
            end
          end
        end
        loops << loop_pts if loop_pts.length >= 3
      end
      loops
    end
  end
end
