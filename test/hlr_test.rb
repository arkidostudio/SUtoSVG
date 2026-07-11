# Isolated unit test for SUtoSVG::Hlr.
# Runs with a plain Ruby interpreter (no SketchUp):
#   ruby test/hlr_test.rb
#
# Uses a trivial orthographic projector: the camera sits at +Z looking toward
# -Z, so screen = (x, y) and depth = -z (larger z is nearer, smaller depth).

require_relative '../src/su_to_svg/hlr'

include SUtoSVG

$failures = 0
def check(desc, cond)
  puts((cond ? '  ok   - ' : '  FAIL - ') + desc)
  $failures += 1 unless cond
end

# --- orthographic projector -------------------------------------------------
PROJ = Object.new
def PROJ.project(p)
  [p[0], p[1]]
end

def PROJ.depth(p)
  -p[2]
end

def PROJ.eye_ray(p)
  [p, [0.0, 0.0, -1.0]]
end

def occ(loops2d, plane)
  xs = loops2d.flatten(1).map { |pt| pt[0] }
  ys = loops2d.flatten(1).map { |pt| pt[1] }
  Hlr::Occluder.new(loops2d, [xs.min, ys.min, xs.max, ys.max], plane)
end

def edge(a, b)
  Hlr::Edge.new(a, b)
end

# Round-trip a Segment to a canonical, order-independent key.
def seg_key(s)
  p, q = s.points
  a = [p[0].round(2), p[1].round(2)]
  b = [q[0].round(2), q[1].round(2)]
  [a, b].sort
end

def has_seg?(segs, a, b)
  segs.map { |s| seg_key(s) }.include?([a, b].sort)
end

# A 10x10 square occluder in the plane z = 5.
SQUARE = occ([[[0, 0], [10, 0], [10, 10], [0, 10]]], [[0, 0, 5], [0, 0, 1]])

puts 'Hlr#visible_segments — single square occluder (plane z=5)'

# 1. Edge fully behind (z=0), inside the silhouette -> hidden.
r = Hlr.visible_segments([SQUARE], [edge([2, 5, 0], [8, 5, 0])], PROJ, min_seg: 0)
check('edge behind the face is fully removed', r.empty?)

# 2. Edge fully in front (z=8) -> fully visible.
r = Hlr.visible_segments([SQUARE], [edge([2, 5, 8], [8, 5, 8])], PROJ, min_seg: 0)
check('edge in front stays fully visible', r.length == 1 && has_seg?(r, [2, 5], [8, 5]))

# 3. Edge behind but straddling the silhouette -> two visible end stubs.
r = Hlr.visible_segments([SQUARE], [edge([-5, 5, 0], [15, 5, 0])], PROJ, min_seg: 0)
check('straddling edge yields two clipped stubs',
      r.length == 2 && has_seg?(r, [-5, 5], [0, 5]) && has_seg?(r, [10, 5], [15, 5]))

# 4. Edge crossing the face plane (front->behind) -> only the front half shows.
r = Hlr.visible_segments([SQUARE], [edge([2, 5, 8], [8, 5, 2])], PROJ, min_seg: 0)
check('plane-crossing edge is cut at the depth crossover',
      r.length == 1 && has_seg?(r, [2, 5], [5, 5]))

# 5. Edge beside the face (outside silhouette) -> untouched.
r = Hlr.visible_segments([SQUARE], [edge([2, -5, 0], [8, -5, 0])], PROJ, min_seg: 0)
check('edge outside the silhouette is untouched',
      r.length == 1 && has_seg?(r, [2, -5], [8, -5]))

# 6. Coplanar edge lying ON the face -> not occluded by that face.
r = Hlr.visible_segments([SQUARE], [edge([2, 5, 5], [8, 5, 5])], PROJ, min_seg: 0)
check('coplanar edge is not hidden by its own plane',
      r.length == 1 && has_seg?(r, [2, 5], [8, 5]))

puts 'Hlr#visible_segments — occluder with a hole'

# Outer 20x20 square with a central 10x10 hole, plane z=5.
HOLED = occ(
  [
    [[0, 0], [20, 0], [20, 20], [0, 20]],   # outer
    [[5, 5], [15, 5], [15, 15], [5, 15]]    # hole
  ],
  [[0, 0, 5], [0, 0, 1]]
)

# 7. Edge behind, crossing the hole -> only the portion under the hole shows.
r = Hlr.visible_segments([HOLED], [edge([0, 10, 0], [20, 10, 0])], PROJ, min_seg: 0)
check('edge behind is visible only through the hole',
      r.length == 1 && has_seg?(r, [5, 10], [15, 10]))

puts 'Hlr#visible_segments — attrs passthrough'

# 8. attrs (e.g. stroke width) copy onto every surviving Segment.
wide = Hlr::Edge.new([-5, 5, 0], [15, 5, 0], :profile) # straddles SQUARE, clips to 2
r = Hlr.visible_segments([SQUARE], [wide], PROJ, min_seg: 0)
check('attrs propagate to all clipped segments',
      r.length == 2 && r.all? { |s| s.attrs == :profile })

puts 'Hlr#visible_segments — depth bias'

# 9. An edge sitting just barely behind the face (z=4.9, face at z=5) is hidden
# with no bias, but a bias larger than the 0.1 depth gap keeps it visible.
near = [edge([2, 5, 4.9], [8, 5, 4.9])]
r0 = Hlr.visible_segments([SQUARE], near, PROJ, min_seg: 0, bias: 0.0)
r1 = Hlr.visible_segments([SQUARE], near, PROJ, min_seg: 0, bias: 0.5)
check('no bias: near-surface edge is clipped', r0.empty?)
check('bias keeps a near-surface edge visible', r1.length == 1)

puts
if $failures.zero?
  puts 'ALL TESTS PASSED'
  exit 0
else
  puts "#{$failures} TEST(S) FAILED"
  exit 1
end
