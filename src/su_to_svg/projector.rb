# SUtoSVG — projection helpers.
#
# Thin wrappers over the SketchUp View/Camera API. `screen_coords` projects a
# world-space Geom::Point3d to 2D screen pixels using the ACTIVE camera, which
# is exactly what makes the export match the current viewport angle.

module SUtoSVG
  module Projector
    module_function

    # World Point3d -> [x, y] screen pixels (top-left origin, y-down).
    def screen_xy(view, world_pt)
      sc = view.screen_coords(world_pt)
      [sc.x.to_f, sc.y.to_f]
    end

    # In perspective mode, points at or behind the camera plane project
    # nonsensically. Detect them so callers can drop the whole face.
    def behind_camera?(view, world_pt)
      cam = view.camera
      return false unless cam.perspective?
      (world_pt - cam.eye).dot(cam.direction) <= 0.0
    end

    # Signed distance along the view direction. Larger == farther from camera.
    # Used as the painter's-algorithm sort key.
    def depth(view, world_pt)
      cam = view.camera
      (world_pt - cam.eye).dot(cam.direction)
    end
  end
end
