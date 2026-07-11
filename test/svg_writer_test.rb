# Isolated unit test for SUtoSVG::SvgWriter.
# Runs with a plain Ruby interpreter (no SketchUp required):
#   ruby test/svg_writer_test.rb

require_relative '../src/su_to_svg/svg_writer'

include SUtoSVG

$failures = 0
def check(desc, cond)
  if cond
    puts "  ok   - #{desc}"
  else
    puts "  FAIL - #{desc}"
    $failures += 1
  end
end

Face = SvgWriter::Face
Edge = SvgWriter::Edge

puts 'SvgWriter#build'

# A solid square (outer loop only) + one edge per weight layer.
square = Face.new([[[10, 10], [30, 10], [30, 30], [10, 30]]], '#ff0000')
thin   = Edge.new([[10, 10], [30, 30]], 1.0, :thin)
medium = Edge.new([[12, 10], [30, 28]], 2.0, :medium)
thick  = Edge.new([[10, 12], [28, 30]], 3.5, :thick)
svg = SvgWriter.build([square], [thin, medium, thick], margin: 5.0)

check('emits an XML declaration', svg.start_with?('<?xml'))
check('has an <svg> root with xmlns', svg.include?('xmlns="http://www.w3.org/2000/svg"'))
# content spans x:10..30 y:10..30 => 20x20, plus margin 5 each side => 30x30.
check('viewBox sized to content + margin', svg.include?('viewBox="0 0 30 30"'))
check('width matches viewBox', svg.include?('width="30"'))
check('renders a filled polygon', svg.include?('<polygon') && svg.include?('fill="#ff0000"'))
# min corner (10,10) shifted by margin(5)-min(10) = -5 => 5,5.
check('normalizes coordinates to origin+margin', svg.include?('points="5,5'))
check('emits a named layer group per weight',
      svg.include?('id="edges-thin"') && svg.include?('id="edges-medium"') && svg.include?('id="edges-thick"'))
check('layers carry Inkscape layer attributes',
      svg.include?('inkscape:groupmode="layer"') && svg.include?('inkscape:label="edges-thick"'))
check('each layer sets its own stroke-width',
      svg.include?('stroke-width="1"') && svg.include?('stroke-width="2"') && svg.include?('stroke-width="3.5"'))
check('layers use black stroke', svg.include?('stroke="#000000"'))
# thin drawn before thick (heavier lines on top)
check('thick layer is drawn last (on top)',
      svg.index('id="edges-thin"') < svg.index('id="edges-thick"'))

# A square with a triangular hole => must use <path> + evenodd.
holed = Face.new(
  [
    [[0, 0], [40, 0], [40, 40], [0, 40]],   # outer
    [[10, 10], [30, 10], [20, 30]]          # hole
  ],
  '#00ff00'
)
svg2 = SvgWriter.build([holed], [], margin: 0.0)
check('holed face uses <path>', svg2.include?('<path'))
check('holed face uses evenodd fill rule', svg2.include?('fill-rule="evenodd"'))
check('path has two subpaths (M...Z M...Z)', svg2.scan(/M/).length >= 2 && svg2.scan(/Z/).length >= 2)
check('omits edge layers when there are no edges', !svg2.include?('id="edges-'))

# Empty input must not crash.
svg3 = SvgWriter.build([], [])
check('empty input yields a valid <svg>', svg3.include?('<svg') && svg3.include?('viewBox'))

# Shadows render in their own layer, at the bottom, under the edges.
shadow = Face.new([[[0, 0], [20, 0], [20, 20], [0, 20]]], '#808080')
edge4  = Edge.new([[5, 5], [15, 15]], 1.0, :thin)
svg4 = SvgWriter.build([], [edge4], shadow_polys: [shadow], shadow_opacity: 0.5, margin: 0.0)
check('shadows get their own labelled layer',
      svg4.include?('id="shadows"') && svg4.include?('inkscape:label="shadows"'))
check('shadow layer carries its opacity', svg4.include?('opacity="0.5"'))
check('shadow layer is drawn before (under) the edges',
      svg4.index('id="shadows"') < svg4.index('id="edges-thin"'))
check('shadow bounds are included in the canvas', svg4.include?('viewBox="0 0 20 20"'))

# Number formatting: trailing zeros stripped, decimals kept.
check('fmt strips trailing zeros', SvgWriter.fmt(30.0) == '30')
check('fmt keeps meaningful decimals', SvgWriter.fmt(12.5) == '12.5')
check('fmt rounds to 2 decimals', SvgWriter.fmt(1.234) == '1.23')

puts
if $failures.zero?
  puts 'ALL TESTS PASSED'
  exit 0
else
  puts "#{$failures} TEST(S) FAILED"
  exit 1
end
