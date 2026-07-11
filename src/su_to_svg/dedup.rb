# SUtoSVG — coincident-line dedup.
#
# Pure Ruby, NO SketchUp dependency. When two objects touch (a box sitting on
# another box), they share the same edges in 3D, so the projection produces two
# identical overlapping lines. This merges collinear segments that overlap (or
# exactly coincide) into a single segment, so shared edges export as one line.
#
# Two segments merge only when they lie on the SAME infinite line (same
# canonical normal + perpendicular offset, within tolerance) AND their extents
# overlap or nearly touch. Separate collinear pieces (e.g. either side of a
# hidden gap left by HLR) are kept apart.

module SUtoSVG
  module Dedup
    DIR_TOL    = 0.02  # unit-normal component bucket (~1 degree)
    OFFSET_TOL = 0.5   # px, perpendicular distance between lines
    MERGE_GAP  = 0.5   # px, gap along the line still treated as overlapping

    module_function

    # segments : Array of [[x0,y0],[x1,y1]].
    # Returns a new Array of merged [[x0,y0],[x1,y1]].
    def merge_segments(segments)
      groups = Hash.new { |h, k| h[k] = [] }
      segments.each do |pts|
        rec = line_record(pts.first, pts.last)
        next unless rec # drop degenerate (zero-length) segments
        key = [(rec[:nx] / DIR_TOL).round, (rec[:ny] / DIR_TOL).round,
               (rec[:off] / OFFSET_TOL).round]
        groups[key] << rec
      end

      out = []
      groups.each_value do |recs|
        r = recs.first
        merge_intervals(recs.map { |x| [x[:t0], x[:t1]] }).each do |t0, t1|
          out << [point_at(r, t0), point_at(r, t1)]
        end
      end
      out
    end

    # Canonical line description for a segment: unit normal (n) pushed into a
    # fixed half so collinear segments share it, perpendicular offset, and the
    # [t0,t1] extent along the in-line direction u = (ny, -nx).
    def line_record(a, b)
      dx = b[0] - a[0]
      dy = b[1] - a[1]
      len = Math.hypot(dx, dy)
      return nil if len < 1e-9
      nx = -dy / len
      ny = dx / len
      if ny < -1e-9 || (ny.abs < 1e-9 && nx < 0) # canonicalize normal direction
        nx = -nx
        ny = -ny
      end
      off = nx * a[0] + ny * a[1]
      ux = ny
      uy = -nx
      ta = ux * a[0] + uy * a[1]
      tb = ux * b[0] + uy * b[1]
      { nx: nx, ny: ny, off: off, t0: [ta, tb].min, t1: [ta, tb].max }
    end

    # Point on the line at parameter t: offset*n + t*u.
    def point_at(rec, t)
      nx = rec[:nx]
      ny = rec[:ny]
      [rec[:off] * nx + t * ny, rec[:off] * ny + t * (-nx)]
    end

    # Union of 1D intervals, merging those that overlap or touch within MERGE_GAP.
    def merge_intervals(intervals)
      sorted = intervals.sort_by { |iv| iv[0] }
      merged = [sorted.first.dup]
      sorted[1..].each do |t0, t1|
        cur = merged.last
        if t0 <= cur[1] + MERGE_GAP
          cur[1] = t1 if t1 > cur[1]
        else
          merged << [t0, t1]
        end
      end
      merged
    end
  end
end
