# SUtoSVG — selection collector.
#
# Recursively walks a set of entities (the selection), descending into groups
# and component instances while accumulating their transformations, and returns
# every Face and Edge resolved to WORLD coordinates.

module SUtoSVG
  module Collector
    # A face resolved to world space.
    #   loops  : Array of loops; loops[0] is the outer loop, rest are holes.
    #            Each loop is an Array of Geom::Point3d (world).
    #   normal : Geom::Vector3d (world), pointing out of the front side.
    #   center : Geom::Point3d (world), centroid of the outer loop.
    #   front  : Sketchup::Material or nil (front material).
    #   back   : Sketchup::Material or nil (back material).
    WorldFace = Struct.new(:loops, :normal, :center, :front, :back)

  # An edge resolved to world space.
  #   a, b         : Geom::Point3d endpoints (world).
  #   normals      : Array of Geom::Vector3d (world) for each adjacent face; used
  #                  to classify profile/silhouette edges. Empty for standalone.
  #   intersection : true for auto-generated solid-intersection creases (always
  #                  drawn at interior weight, never profile).
  WorldEdge = Struct.new(:a, :b, :normals, :intersection)

    module_function

    # entities : anything that responds to #each yielding Sketchup::Entity
    #            (a Selection, Entities, or Array).
    # Returns { faces: Array<WorldFace>, edges: Array<WorldEdge> }.
    def collect(entities, transform = Geom::Transformation.new)
      out = { faces: [], edges: [] }
      walk(entities, transform, out)
      out
    end

    def walk(entities, tr, out)
      entities.each do |e|
        case e
        when Sketchup::Face
          out[:faces] << build_face(e, tr)
        when Sketchup::Edge
          normals = e.faces.map { |f| f.normal.transform(tr) }
          out[:edges] << WorldEdge.new(e.start.position.transform(tr),
                                       e.end.position.transform(tr),
                                       normals)
        when Sketchup::Group
          walk(e.entities, tr * e.transformation, out)
        when Sketchup::ComponentInstance
          walk(e.definition.entities, tr * e.transformation, out)
        end
      end
    end

    def build_face(face, tr)
      outer = face.outer_loop
      ordered = [outer] + (face.loops - [outer])
      loops = ordered.map do |loop|
        loop.vertices.map { |v| v.position.transform(tr) }
      end
      WorldFace.new(
        loops,
        face.normal.transform(tr).normalize,
        centroid(loops.first),
        face.material,
        face.back_material
      )
    end

    def centroid(points)
      return Geom::Point3d.new if points.empty?
      sx = sy = sz = 0.0
      points.each do |p|
        sx += p.x
        sy += p.y
        sz += p.z
      end
      n = points.length
      Geom::Point3d.new(sx / n, sy / n, sz / n)
    end
  end
end
