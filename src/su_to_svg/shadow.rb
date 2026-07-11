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
  end
end
