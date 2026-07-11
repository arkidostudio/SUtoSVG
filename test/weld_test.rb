# Isolated unit test for SUtoSVG::Weld (no SketchUp):
#   ruby test/weld_test.rb
require_relative '../src/su_to_svg/weld'
include SUtoSVG

$failures = 0
def check(desc, cond)
  puts((cond ? '  ok   - ' : '  FAIL - ') + desc)
  $failures += 1 unless cond
end

E = Struct.new(:points)
def near(p, x, y, tol = 0.01)
  (p[0] - x).abs < tol && (p[1] - y).abs < tol
end

puts 'Weld#close_gaps'

# A horizontal edge whose right tip stops 1px short of a vertical line it should
# meet -> extended along its own axis to the crossing point (10,0).
a = E.new([[0.0, 0.0], [9.0, 0.0]])
b = E.new([[10.0, -5.0], [10.0, 5.0]])
Weld.close_gaps([a, b], threshold: 12.0)
check('dangling tip extends to the crossing line', near(a.points.last, 10.0, 0.0))
check('the target line is left unchanged', near(b.points.first, 10.0, -5.0) && near(b.points.last, 10.0, 5.0))

# A gap wider than the threshold is left alone.
c = E.new([[0.0, 0.0], [9.0, 0.0]])
d = E.new([[30.0, -5.0], [30.0, 5.0]])
Weld.close_gaps([c, d], threshold: 12.0)
check('gap beyond threshold is not welded', near(c.points.last, 9.0, 0.0))

# Endpoints that already meet (shared vertex) are not touched.
e = E.new([[0.0, 0.0], [10.0, 0.0]])
f = E.new([[10.0, 0.0], [10.0, 10.0]])
Weld.close_gaps([e, f], threshold: 12.0)
check('already-joined endpoints are untouched',
      near(e.points.last, 10.0, 0.0) && near(f.points.first, 10.0, 0.0))

# An isolated edge with no neighbour stays put.
g = E.new([[100.0, 100.0], [110.0, 100.0]])
Weld.close_gaps([g], threshold: 12.0)
check('isolated edge is unchanged', near(g.points.first, 100.0, 100.0) && near(g.points.last, 110.0, 100.0))

# Weld only moves along the edge's own axis: a tip is NOT pulled sideways to a
# line that its extension doesn't cross.
h = E.new([[0.0, 0.0], [9.0, 0.0]])          # extends along +x
k = E.new([[3.0, 2.0], [3.0, 20.0]])         # vertical line above, off-axis
Weld.close_gaps([h, k], threshold: 12.0)
check('tip is not pulled sideways off its axis', near(h.points.last, 9.0, 0.0))

puts
if $failures.zero?
  puts 'ALL TESTS PASSED'
  exit 0
else
  puts "#{$failures} TEST(S) FAILED"
  exit 1
end
