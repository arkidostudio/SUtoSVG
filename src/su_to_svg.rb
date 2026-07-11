# SUtoSVG — registrar
#
# This is the file SketchUp loads on startup. It registers the extension so it
# shows up in Extension Manager and lazy-loads the real code from su_to_svg/main.rb.

require 'sketchup.rb'
require 'extensions.rb'

module SUtoSVG
  unless defined?(@extension_loaded) && @extension_loaded
    ext = SketchupExtension.new(
      'Export Selection to SVG',
      File.join('su_to_svg', 'main')
    )
    ext.description = 'Exports the current selection to an SVG file, projected ' \
                      'exactly as it appears in the viewport (current camera).'
    ext.version = '1.0.0'
    ext.copyright = '2026'
    ext.creator = 'SUtoSVG'

    Sketchup.register_extension(ext, true)
    @extension_loaded = true
  end
end
