# Generates a sample SVG (a fake axonometric cube) to eyeball the writer output.
#   ruby test/make_sample.rb  ->  sample_cube.svg
require_relative '../src/su_to_svg/svg_writer'
include SUtoSVG

F = SvgWriter::Face
E = SvgWriter::Edge

faces = [
  F.new([[[60, 20], [140, 20], [180, 60], [100, 60]]], '#8fa8c8'),   # top
  F.new([[[60, 20], [100, 60], [100, 140], [60, 100]]], '#5b7ea6'),  # left
  F.new([[[100, 60], [180, 60], [180, 140], [100, 140]]], '#3f5f82') # right
]
edges = [
  [[60, 20], [140, 20]], [[140, 20], [180, 60]], [[60, 20], [100, 60]],
  [[100, 60], [180, 60]], [[60, 20], [60, 100]], [[60, 100], [100, 140]],
  [[100, 60], [100, 140]], [[100, 140], [180, 140]], [[180, 60], [180, 140]]
].map { |pts| E.new(pts, 1.5) }

out = File.join(File.dirname(__FILE__), '..', 'sample_cube.svg')
File.write(out, SvgWriter.build(faces, edges, margin: 10))
puts "wrote #{File.expand_path(out)} (#{File.size(out)} bytes)"
