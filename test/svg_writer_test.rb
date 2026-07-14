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

# Ground shadow: its own layer, merged into one path, under the edges.
g1 = Face.new([[[0, 0], [20, 0], [20, 20], [0, 20]]], '#c0c0c0')
g2 = Face.new([[[10, 5], [30, 5], [30, 25], [10, 25]]], '#c0c0c0') # overlaps g1
edge4  = Edge.new([[5, 5], [15, 15]], 1.0, :thin)
svg4 = SvgWriter.build([], [edge4], shadow_polys: [g1, g2], margin: 0.0)
check('ground shadow gets its own labelled layer',
      svg4.include?('id="shadow-ground"') && svg4.include?('inkscape:label="shadow-ground"'))
check('ground shadow is merged into one path (not many polygons)',
      svg4.scan(/<path/).length == 1 && !svg4.include?('<polygon'))
check('merged path uses evenodd union', svg4.include?('fill-rule="evenodd"'))
check('shadow layer is drawn before (under) the edges',
      svg4.index('id="shadow-ground"') < svg4.index('id="edges-thin"'))

# Fills: a face and a cast-shadow group are drawn together (depth-ordered).
# A cast group with no mask_loops draws as a plain shape.
face_white = Face.new([[[0, 0], [10, 0], [10, 10], [0, 10]]], '#ffffff')
cast = { polys: [Face.new([[[22, 2], [34, 2], [34, 18], [22, 18]]], '#c0c0c0'),
                 Face.new([[[28, 2], [38, 2], [38, 18], [28, 18]]], '#c0c0c0')] } # two overlapping pieces
svg5 = SvgWriter.build([face_white, cast], [], margin: 0.0)
check('faces + cast shadows share the faces layer', svg5.include?('id="faces"'))
check('unmasked cast shadow carries no mask attribute', !svg5.include?('mask='))
check('overlapping cast pieces merge via evenodd', svg5.include?('fill-rule="evenodd"'))

# Shadow-only input (no face fills) uses the shadow-faces layer id.
svg_so = SvgWriter.build([cast], [], margin: 0.0)
check('shadow-only fills use the shadow-faces layer id', svg_so.include?('id="shadow-faces"'))

# Face-shadows with mask_loops have the mask BAKED IN via polygon subtraction.
# The output is a plain path with no <mask>/mask=... anywhere, and the visible
# area is the shadow minus the mask silhouette.
masked = { polys: [Face.new([[[10, 10], [40, 10], [40, 40], [10, 40]]], '#c0c0c0')],
           mask_loops: [[[15, 5], [25, 5], [25, 45], [15, 45]]] }
svg_m = SvgWriter.build([masked], [], margin: 0.0)
check('baked face-shadow has no <mask> element', !svg_m.include?('<mask'))
check('baked face-shadow has no mask= attr',    !svg_m.include?('mask='))
# Shadow was 30×30 = 900; mask strip is x∈[15,25] across the whole shadow →
# remove 10×30 = 300, leaving 600. Roughly a bbox 50×50 minus a 10-wide strip.
check('baked face-shadow shape still visible', svg_m.include?('<path d="M'))

# Ground shadow with ground_mask: subtraction baked into the emitted shape too.
gpoly = Face.new([[[0, 0], [100, 0], [100, 20], [0, 20]]], '#c0c0c0')
svg_g = SvgWriter.build([], [], shadow_polys: [gpoly],
                        ground_mask: [[[40, 0], [60, 0], [60, 20], [40, 20]]], margin: 0.0)
check('baked ground shadow has no <mask>/mask=',
      !svg_g.include?('<mask') && !svg_g.include?('mask='))
check('ground shadow still emits a path', svg_g.include?('<path'))

# A single, pre-unioned face (with a hole) is drawn directly, honouring the hole.
holed = Face.new([[[0, 0], [40, 0], [40, 40], [0, 40]], [[10, 10], [30, 10], [30, 30], [10, 30]]], '#c0c0c0')
svg6 = SvgWriter.build([], [], shadow_polys: [holed], margin: 0.0)
check('a pre-unioned shadow with a hole uses evenodd', svg6.include?('fill-rule="evenodd"'))

# Degenerate (edge-on) geometry is culled: zero-area faces, zero-area shadow
# pieces, duplicate loops — and empty layers are omitted entirely.
flat_face   = Face.new([[[8, 100], [8, 100], [267, 100], [267, 100]]], '#ffffff') # zero area
real_face   = Face.new([[[0, 0], [50, 0], [50, 50], [0, 50]]], '#ffffff')
flat_shadow = Face.new([[[8, 787], [267, 787], [8, 787], [267, 787]]], '#c0c0c0')
dup_a       = Face.new([[[0, 60], [40, 60], [40, 90], [0, 90]]], '#c0c0c0')
dup_b       = Face.new([[[0, 60], [40, 60], [40, 90], [0, 90]]], '#c0c0c0') # identical
svg6 = SvgWriter.build([flat_face, real_face, { polys: [flat_shadow] }, { polys: [dup_a, dup_b, flat_shadow] }],
                       [], shadow_polys: [flat_shadow], margin: 0.0)
check('zero-area faces are culled', svg6.scan(/<polygon/).length == 1)
check('edge-on ground shadow omits the whole layer', !svg6.include?('shadow-ground'))
check('degenerate pieces + duplicate loops collapse to one evenodd subpath',
      svg6.scan(/fill-rule="evenodd"/).length == 1 &&
      svg6[/d="([^"]*)" fill-rule="evenodd"/, 1].scan(/M/).length == 1)

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
