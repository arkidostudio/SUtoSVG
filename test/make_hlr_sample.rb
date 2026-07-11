# End-to-end HLR demo (no SketchUp): projects a cube isometrically, runs hidden
# line removal, and writes cube_hlr.svg (+ cube_wire.svg for comparison).
#   ruby test/make_hlr_sample.rb
#
# The camera looks from the (1,1,1) direction, so the near corner is (10,10,10)
# and the far corner (0,0,0). The three edges meeting at (0,0,0) are hidden and
# must be removed by HLR.
require_relative '../src/su_to_svg/hlr'
require_relative '../src/su_to_svg/svg_writer'
include SUtoSVG

# Isometric parallel projector onto the plane perpendicular to view dir (1,1,1).
S = 12.0 # scale
PROJ = Object.new
def PROJ.project(p)
  u = (p[0] - p[1]) / Math.sqrt(2)               # right axis
  v = (p[0] + p[1] - 2 * p[2]) / Math.sqrt(6)    # up axis
  [S * u, -S * v] # screen y is down
end

def PROJ.depth(p)
  -(p[0] + p[1] + p[2]) # toward (1,1,1) is nearer -> smaller depth
end

def PROJ.eye_ray(p)
  [p, [-1.0, -1.0, -1.0]] # parallel projection, view dir into the scene
end

def quad(a, b, c, d, n)
  loops2d = [[a, b, c, d].map { |pt| PROJ.project(pt) }]
  xs = loops2d[0].map { |pt| pt[0] }
  ys = loops2d[0].map { |pt| pt[1] }
  Hlr::Occluder.new(loops2d, [xs.min, ys.min, xs.max, ys.max], [a, n])
end

# Cube [0,10]^3 faces (outward normals).
faces = [
  quad([0, 0, 0], [0, 10, 0], [0, 10, 10], [0, 0, 10], [-1, 0, 0]),   # x=0
  quad([10, 0, 0], [10, 0, 10], [10, 10, 10], [10, 10, 0], [1, 0, 0]), # x=10
  quad([0, 0, 0], [0, 0, 10], [10, 0, 10], [10, 0, 0], [0, -1, 0]),   # y=0
  quad([0, 10, 0], [10, 10, 0], [10, 10, 10], [0, 10, 10], [0, 1, 0]), # y=10
  quad([0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0], [0, 0, -1]),   # z=0
  quad([0, 0, 10], [0, 10, 10], [10, 10, 10], [10, 0, 10], [0, 0, 1]) # z=10
]

edges = [
  [[0, 0, 0], [10, 0, 0]], [[10, 0, 0], [10, 10, 0]],
  [[10, 10, 0], [0, 10, 0]], [[0, 10, 0], [0, 0, 0]],
  [[0, 0, 10], [10, 0, 10]], [[10, 0, 10], [10, 10, 10]],
  [[10, 10, 10], [0, 10, 10]], [[0, 10, 10], [0, 0, 10]],
  [[0, 0, 0], [0, 0, 10]], [[10, 0, 0], [10, 0, 10]],
  [[10, 10, 0], [10, 10, 10]], [[0, 10, 0], [0, 10, 10]]
].map { |(a, b)| Hlr::Edge.new(a, b) }

hlr_pts  = Hlr.visible_segments(faces, edges, PROJ).map(&:points)
wire_pts = edges.map { |e| [PROJ.project(e.a3), PROJ.project(e.b3)] }

def write_svg(path, pts_list)
  edge_objs = pts_list.map { |pts| SvgWriter::Edge.new(pts, 1.5, :thin) }
  File.write(path, SvgWriter.build([], edge_objs, margin: 10))
end

hlr_path  = File.join(File.dirname(__FILE__), '..', 'cube_hlr.svg')
wire_path = File.join(File.dirname(__FILE__), '..', 'cube_wire.svg')
write_svg(hlr_path, hlr_pts)
write_svg(wire_path, wire_pts)

puts "wireframe: #{wire_pts.length} segments"
puts "with HLR:  #{hlr_pts.length} segments"
puts "wrote #{File.expand_path(hlr_path)}"
puts "wrote #{File.expand_path(wire_path)}"
