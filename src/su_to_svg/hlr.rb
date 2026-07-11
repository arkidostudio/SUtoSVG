# SUtoSVG — hidden-line removal.
#
# Pure Ruby, NO SketchUp dependency. All 3D math runs on plain [x, y, z] arrays,
# and everything camera-related is delegated to an injected `projector` object.
# That keeps the algorithm unit-testable with a simple orthographic projector.
#
# The projector must respond to (all points/vectors are 3-element arrays):
#   project(p3) -> [x, y]        screen-space pixels for a world point
#   depth(p3)   -> Float         monotonic camera depth; LARGER == farther away
#   eye_ray(p3) -> [origin3, dir3]
#                                the viewing ray passing through p3's screen
#                                point (origin=eye + dir=(p-eye) for perspective;
#                                origin=p + dir=view_direction for parallel)
#
# Algorithm (pairwise edge/face clipping, Appel-style):
#   For each edge, start with the whole parameter range [0,1] as "visible".
#   For each face:
#     1. Find where the edge's 2D projection enters/exits the face's 2D
#        silhouette (segment-vs-polygon crossings; holes handled via even-odd).
#     2. Split each covered interval at the point where the edge crosses the
#        face's 3D plane (there the depth ordering flips).
#     3. Test each sub-interval's midpoint in 3D: if the face is strictly nearer
#        along that viewing ray, subtract the sub-interval from "visible".
#   Whatever survives is emitted as 2D line segments.

module SUtoSVG
  module Hlr
    # loops2d : Array of loops; loops2d[0] is the outer loop, rest are holes.
    #           Each loop is an Array of [x, y] (screen pixels).
    # bbox2d  : [min_x, min_y, max_x, max_y] screen-space bounds (quick reject).
    # plane   : [p0(3), n(3)] — a point on the face and its (world) normal.
    Occluder = Struct.new(:loops2d, :bbox2d, :plane)
    # a3, b3 : edge endpoints as [x, y, z] world arrays.
    # attrs  : opaque payload (e.g. stroke width) copied onto every output
    #          Segment this edge produces.
    Edge = Struct.new(:a3, :b3, :attrs)
    # A surviving visible piece of an edge.
    #   points : [[x0, y0], [x1, y1]] screen coords.
    #   attrs  : the source edge's attrs.
    Segment = Struct.new(:points, :attrs)

    T_EPS     = 1e-7    # parameter-space tolerance
    DEN_EPS   = 1e-12   # near-parallel guard for ray/plane math
    DEFAULT_MIN_SEG = 0.3 # drop visible slivers shorter than this (px)

    module_function

    # occluders : Array<Occluder> — every face acts as an opaque occluder.
    # edges     : Array<Edge>.
    # projector : see module doc.
    # bias      : depth margin (world units). A face must be nearer than an edge
    #             point by more than `bias` to hide it. Keeps edges lying on (or
    #             meeting at) a surface from being over-clipped at joints.
    # Returns Array<Segment>.
    def visible_segments(occluders, edges, projector, min_seg: DEFAULT_MIN_SEG, bias: 0.0)
      out = []
      edges.each do |edge|
        out.concat(clip_edge(occluders, edge, projector, min_seg, bias))
      end
      out
    end

    # --- per-edge clipping ---------------------------------------------------

    def clip_edge(occluders, edge, projector, min_seg, bias)
      a3 = edge.a3
      b3 = edge.b3
      a2 = projector.project(a3)
      b2 = projector.project(b3)
      dx = b2[0] - a2[0]
      dy = b2[1] - a2[1]
      return [] if Math.hypot(dx, dy) < min_seg # edge seen (nearly) end-on

      ebb = [[a2[0], b2[0]].min, [a2[1], b2[1]].min,
             [a2[0], b2[0]].max, [a2[1], b2[1]].max]

      visible = [[0.0, 1.0]]
      occluders.each do |occ|
        break if visible.empty?
        next unless bbox_overlap?(ebb, occ.bbox2d)

        each_covered_subinterval(occ, a2, b2, a3, b3) do |s0, s1|
          mid3 = lerp3(a3, b3, (s0 + s1) / 2.0)
          visible = subtract(visible, s0, s1) if occluded?(occ.plane, mid3, projector, bias)
        end
      end

      segs = []
      visible.each do |(t0, t1)|
        p0 = [a2[0] + dx * t0, a2[1] + dy * t0]
        p1 = [a2[0] + dx * t1, a2[1] + dy * t1]
        next if Math.hypot(p1[0] - p0[0], p1[1] - p0[1]) < min_seg
        segs << Segment.new([p0, p1], edge.attrs)
      end
      segs
    end

    # Yields [s0, s1] for every edge sub-interval that is (a) inside the face's
    # 2D silhouette and (b) on one consistent side of the face's plane.
    def each_covered_subinterval(occ, a2, b2, a3, b3)
      crossings = [0.0, 1.0]
      occ.loops2d.each do |loop|
        n = loop.length
        i = 0
        while i < n
          t = seg_param(a2, b2, loop[i], loop[(i + 1) % n])
          crossings << t if t
          i += 1
        end
      end
      crossings.sort!

      tc = plane_cross_t(a3, b3, occ.plane) # where the edge pierces the plane
      k = 0
      while k < crossings.length - 1
        t0 = crossings[k]
        t1 = crossings[k + 1]
        k += 1
        next if t1 - t0 < T_EPS
        tm = (t0 + t1) / 2.0
        next unless inside?(occ.loops2d,
                            a2[0] + (b2[0] - a2[0]) * tm,
                            a2[1] + (b2[1] - a2[1]) * tm)

        if tc && tc > t0 + T_EPS && tc < t1 - T_EPS
          yield t0, tc
          yield tc, t1
        else
          yield t0, t1
        end
      end
    end

    # Is the face nearer than the 3D point `p3` (by more than `bias`) along its
    # viewing ray? `bias` is an absolute world-depth margin; when 0 it falls back
    # to a tiny relative tolerance (just enough that coplanar faces don't occlude).
    def occluded?(plane, p3, projector, bias = 0.0)
      p0, n = plane
      origin, dir = projector.eye_ray(p3)
      den = dot3(n, dir).to_f
      return false if den.abs < DEN_EPS # ray grazes the plane
      tr = dot3(n, sub3(p0, origin)) / den
      hit = [origin[0] + dir[0] * tr, origin[1] + dir[1] * tr, origin[2] + dir[2] * tr]
      pd = projector.depth(p3)
      tol = bias > 0.0 ? bias : 1e-4 * (1.0 + pd.abs)
      projector.depth(hit) < pd - tol
    end

    # --- interval arithmetic -------------------------------------------------

    def subtract(intervals, h0, h1)
      return intervals if h1 <= h0 + T_EPS
      out = []
      intervals.each do |(t0, t1)|
        if h1 <= t0 + T_EPS || h0 >= t1 - T_EPS
          out << [t0, t1] # disjoint
        else
          out << [t0, h0] if h0 > t0 + T_EPS
          out << [h1, t1] if t1 > h1 + T_EPS
        end
      end
      out
    end

    # --- 2D helpers ----------------------------------------------------------

    def bbox_overlap?(a, b)
      a[0] <= b[2] && a[2] >= b[0] && a[1] <= b[3] && a[3] >= b[1]
    end

    # Parameter t in (0,1) along segment a2->b2 where it crosses segment p->q,
    # or nil. Endpoints excluded to avoid double-counting shared vertices.
    def seg_param(a2, b2, p, q)
      rx = b2[0] - a2[0]
      ry = b2[1] - a2[1]
      sx = q[0] - p[0]
      sy = q[1] - p[1]
      den = (rx * sy - ry * sx).to_f
      return nil if den.abs < DEN_EPS # parallel / collinear
      px = p[0] - a2[0]
      py = p[1] - a2[1]
      t = (px * sy - py * sx) / den
      u = (px * ry - py * rx) / den
      return nil unless t > T_EPS && t < 1.0 - T_EPS
      return nil unless u >= -T_EPS && u <= 1.0 + T_EPS
      t
    end

    # Even-odd point-in-polygon across all loops (outer + holes).
    def inside?(loops2d, x, y)
      c = false
      loops2d.each do |loop|
        n = loop.length
        j = n - 1
        i = 0
        while i < n
          xi = loop[i][0]
          yi = loop[i][1]
          xj = loop[j][0]
          yj = loop[j][1]
          if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi).to_f + xi
            c = !c
          end
          j = i
          i += 1
        end
      end
      c
    end

    # --- 3D helpers ----------------------------------------------------------

    def plane_cross_t(a3, b3, plane)
      p0, n = plane
      ba = sub3(b3, a3)
      den = dot3(n, ba).to_f
      return nil if den.abs < DEN_EPS # edge parallel to plane
      dot3(n, sub3(p0, a3)) / den
    end

    def sub3(a, b)
      [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
    end

    def dot3(a, b)
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    end

    def lerp3(a, b, t)
      [a[0] + (b[0] - a[0]) * t,
       a[1] + (b[1] - a[1]) * t,
       a[2] + (b[2] - a[2]) * t]
    end
  end
end
