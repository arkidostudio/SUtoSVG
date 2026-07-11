# Isolated unit test for SUtoSVG::Dedup (no SketchUp):
#   ruby test/dedup_test.rb
require_relative '../src/su_to_svg/dedup'
include SUtoSVG

$failures = 0
def check(desc, cond)
  puts((cond ? '  ok   - ' : '  FAIL - ') + desc)
  $failures += 1 unless cond
end

# Canonical key for an unordered segment, rounded, for comparison.
def key(seg)
  a, b = seg
  [[a[0].round(2), a[1].round(2)], [b[0].round(2), b[1].round(2)]].sort
end

def has(result, a, b)
  result.map { |s| key(s) }.include?(key([a, b]))
end

puts 'Dedup#merge_segments'

# 1. Two identical horizontal segments -> one.
r = Dedup.merge_segments([[[0, 0], [10, 0]], [[0, 0], [10, 0]]])
check('identical segments collapse to one', r.length == 1 && has(r, [0, 0], [10, 0]))

# 2. Reversed duplicate (same line, opposite direction) -> one.
r = Dedup.merge_segments([[[0, 0], [10, 0]], [[10, 0], [0, 0]]])
check('reversed duplicate collapses to one', r.length == 1 && has(r, [0, 0], [10, 0]))

# 3. Overlapping collinear segments -> merged union.
r = Dedup.merge_segments([[[0, 0], [10, 0]], [[6, 0], [16, 0]]])
check('overlapping collinear merge to their union', r.length == 1 && has(r, [0, 0], [16, 0]))

# 4. Collinear but separated by a real gap -> stay separate.
r = Dedup.merge_segments([[[0, 0], [10, 0]], [[30, 0], [40, 0]]])
check('separated collinear pieces are kept apart', r.length == 2)

# 5. Parallel lines at different offsets -> not merged.
r = Dedup.merge_segments([[[0, 0], [10, 0]], [[0, 5], [10, 5]]])
check('parallel offset lines are not merged', r.length == 2)

# 6. Perpendicular lines -> not merged.
r = Dedup.merge_segments([[[0, 0], [10, 0]], [[0, 0], [0, 10]]])
check('perpendicular lines are not merged', r.length == 2)

# 7. Vertical duplicates (guards against angle-wrap bugs) -> one.
r = Dedup.merge_segments([[[5, 0], [5, 20]], [[5, 20], [5, 0]]])
check('vertical duplicates collapse to one', r.length == 1 && has(r, [5, 0], [5, 20]))

# 8. Diagonal duplicates -> one.
r = Dedup.merge_segments([[[0, 0], [10, 10]], [[0, 0], [10, 10]]])
check('diagonal duplicates collapse to one', r.length == 1 && has(r, [0, 0], [10, 10]))

# 9. A shared box edge from two stacked boxes (four dup pairs) -> four lines.
sq = [[[0, 0], [10, 0]], [[10, 0], [10, 10]], [[10, 10], [0, 10]], [[0, 10], [0, 0]]]
r = Dedup.merge_segments(sq + sq) # top of lower box == bottom of upper box
check('a doubled square collapses to four edges', r.length == 4)

puts
if $failures.zero?
  puts 'ALL TESTS PASSED'
  exit 0
else
  puts "#{$failures} TEST(S) FAILED"
  exit 1
end
