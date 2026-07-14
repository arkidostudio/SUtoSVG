# Isolated unit test for SUtoSVG::Shadow (no SketchUp):
#   ruby test/shadow_test.rb
require_relative '../src/su_to_svg/shadow'
include SUtoSVG

$failures = 0
def check(desc, cond)
  puts((cond ? '  ok   - ' : '  FAIL - ') + desc)
  $failures += 1 unless cond
end

def near(p, x, y, z, tol = 1e-6)
  p && (p[0] - x).abs < tol && (p[1] - y).abs < tol && (p[2] - z).abs < tol
end

puts 'Shadow#project_to_ground'

# Straight-down light: point drops to directly below it.
check('straight-down light drops to the point below',
      near(Shadow.project_to_ground([3, 4, 10], [0, 0, -1], 0), 3, 4, 0))

# 45-degree light along +x: a point 10 up casts 10 along +x.
check('angled light offsets the shadow along the light',
      near(Shadow.project_to_ground([0, 0, 10], [1, 0, -1], 0), 10, 0, 0))

# Non-zero ground height.
check('respects a raised ground plane',
      near(Shadow.project_to_ground([0, 0, 10], [0, 0, -1], 4), 0, 0, 4))

# Light pointing up (sun below horizon) can't cast onto ground below the point.
check('upward light casts nothing', Shadow.project_to_ground([0, 0, 10], [0, 0, 1], 0).nil?)

# Light parallel to the plane -> no intersection.
check('light parallel to ground yields nil', Shadow.project_to_ground([0, 0, 10], [1, 0, 0], 0).nil?)

# A point below the receiving plane can't cast onto it.
check('point below the plane yields nil', Shadow.project_to_ground([0, 0, -5], [0, 0, -1], 0).nil?)

puts 'Shadow#project_loop'

# A square lifted 10 up, straight-down light -> same square at z=0.
loop = [[0, 0, 10], [10, 0, 10], [10, 10, 10], [0, 10, 10]]
r = Shadow.project_loop(loop, [0, 0, -1], 0)
check('projects a whole loop to the ground',
      r.length == 4 && near(r[0], 0, 0, 0) && near(r[2], 10, 10, 0))

# If any vertex can't project, the whole loop is dropped (nil).
mixed = [[0, 0, 10], [0, 0, -5]] # second vertex is below the plane
check('drops the loop if any vertex fails', Shadow.project_loop(mixed, [0, 0, -1], 0).nil?)

puts 'Shadow#project_to_plane'

# Onto a tilted plane (normal +x, through x=5): a point casts along the light
# until it meets x = 5.
r = Shadow.project_to_plane([0, 0, 10], [1, 0, 0], [5, 0, 0], [1, 0, 0])
check('projects onto a vertical plane', near(r, 5, 0, 10))

# Caster on the far side of the plane from the light -> nil (t < 0).
check('caster on the far side casts nothing',
      Shadow.project_to_plane([10, 0, 0], [1, 0, 0], [5, 0, 0], [1, 0, 0]).nil?)

# Light parallel to the plane -> nil.
check('light parallel to the plane yields nil',
      Shadow.project_to_plane([0, 0, 10], [0, 1, 0], [5, 0, 0], [1, 0, 0]).nil?)

puts 'Shadow#clip_to_halfspace'

# A square straddling the plane x=5 (normal +x): keep only x >= 5, so it becomes
# the right half (a polygon from x=5 to x=10), not dropped entirely.
sq = [[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0]]
clipped = Shadow.clip_to_halfspace(sq, [5, 0, 0], [1, 0, 0])
xs = clipped.map { |p| p[0] }
check('straddling polygon is trimmed, not dropped', clipped.length >= 3)
check('clipped polygon stays on the +x side', xs.min >= 5 - 1e-6 && xs.max <= 10 + 1e-6)

# Entirely on the far side -> empty.
far = Shadow.clip_to_halfspace(sq, [20, 0, 0], [1, 0, 0])
check('polygon fully behind the plane is removed', far.empty?)

# Entirely in front -> unchanged count.
front = Shadow.clip_to_halfspace(sq, [-5, 0, 0], [1, 0, 0])
check('polygon fully in front is kept', front.length == 4)

puts 'Shadow#clip_polygon (2D)'

box = [[0, 0], [10, 0], [10, 10], [0, 10]]

# Subject overhanging the clip box -> trimmed to the overlap.
over = [[5, 5], [20, 5], [20, 8], [5, 8]]
r = Shadow.clip_polygon(over, box)
xs = r.map { |p| p[0] }
check('overhanging polygon is trimmed to the clip box',
      r.length >= 3 && xs.max <= 10 + 1e-6 && xs.min >= 5 - 1e-6)

# Fully inside -> unchanged; fully outside -> empty.
check('inside polygon is unchanged',
      Shadow.clip_polygon([[2, 2], [4, 2], [4, 4], [2, 4]], box).length == 4)
check('outside polygon clips to nothing',
      Shadow.clip_polygon([[20, 20], [30, 20], [30, 30], [20, 30]], box).empty?)

# Clip polygon given in opposite (clockwise) winding still works.
r = Shadow.clip_polygon(over, box.reverse)
check('clockwise clip winding is normalized', r.length >= 3 && r.map { |p| p[0] }.max <= 10 + 1e-6)

puts 'Shadow#union_polygons'

# Two overlapping squares → one L-shape with the right area.
sqA = [[0, 0], [2, 0], [2, 2], [0, 2]]
sqB = [[1, 1], [3, 1], [3, 3], [1, 3]]
loops = Shadow.union_polygons([sqA, sqB])
area = loops.sum { |l| Shadow.signed_area2d(l).abs }
check('two overlapping squares union to one loop', loops.length == 1)
check('L-shape union area = 7 (4 + 4 - 1)', (area - 7.0).abs < 1e-3)

# Fully-contained polygon disappears.
outer = [[0, 0], [3, 0], [3, 3], [0, 3]]
inner = [[0.5, 0.5], [1.5, 0.5], [1.5, 1.5], [0.5, 1.5]]
loops = Shadow.union_polygons([outer, inner])
check('contained polygon disappears', loops.length == 1)
check('outer area preserved', (Shadow.signed_area2d(loops[0]).abs - 9.0).abs < 1e-3)

# Disjoint → two loops.
d1 = [[0, 0], [1, 0], [1, 1], [0, 1]]
d2 = [[5, 5], [6, 5], [6, 6], [5, 6]]
loops = Shadow.union_polygons([d1, d2])
check('disjoint polygons stay as two loops', loops.length == 2)

# CW input is normalized to CCW output.
cw = [[0, 0], [0, 2], [2, 2], [2, 0]]
loops = Shadow.union_polygons([cw])
check('CW polygon normalizes to CCW', loops.length == 1 && Shadow.signed_area2d(loops[0]) > 0)

puts
if $failures.zero?
  puts 'ALL TESTS PASSED'
  exit 0
else
  puts "#{$failures} TEST(S) FAILED"
  exit 1
end
