# SUtoSVG — main entry point: menu wiring + export orchestration.

require 'sketchup.rb'
require File.join(File.dirname(__FILE__), 'collector')
require File.join(File.dirname(__FILE__), 'projector')
require File.join(File.dirname(__FILE__), 'hlr')
require File.join(File.dirname(__FILE__), 'dedup')
require File.join(File.dirname(__FILE__), 'weld')
require File.join(File.dirname(__FILE__), 'shadow')
require File.join(File.dirname(__FILE__), 'svg_writer')

module SUtoSVG
  # --- options -------------------------------------------------------------
  # Pure line drawing by default: faces are NOT filled, but are still used to
  # occlude hidden edges. Set DRAW_FACES = true to render filled polygons too.
  DRAW_FACES        = false
  DRAW_EDGES        = true
  USE_HLR           = true  # clip hidden edges against occluding faces
  # Auto-generate the crease edges where separate solids interpenetrate, using
  # SketchUp's own intersection engine in a throwaway group (the model is left
  # untouched). Lets you skip running Intersect Faces by hand.
  AUTO_INTERSECT    = true
  # Merge coincident/overlapping collinear lines (shared edges of objects that
  # touch) into a single line so they don't export doubled up.
  DEDUP_OVERLAPS    = true
  # Built-in cast shadow: project the selection along SketchUp's sun vector onto
  # a ground plane and draw it in the "shadows" layer. Computed at export time
  # from the model's current sun position; only when SketchUp shadows are on.
  EXPORT_CAST_SHADOW = true
  SHADOW_GROUND      = :auto # :auto = base (min Z) of the selection, or a number
  # Cast shadows from one object onto another object's faces, clipped to each
  # face and depth-interleaved with the shaded faces so they occlude correctly.
  RECEIVE_ON_FACES   = true
  # Also pick up shadow groups made by the TIG-shadowProjector extension, if any
  # are in the selection (kept for compatibility; the built-in caster needs no
  # other extension).
  EXPORT_SHADOWS    = true
  SHADOW_FILL       = '#808080'
  SHADOW_OPACITY    = 0.5
  # Knock the shadow out from behind the objects (so it isn't drawn over them)
  # by masking with opaque object silhouettes. Assumes a white page background.
  MASK_SHADOW       = true
  SHADOW_MASK_COLOR = '#ffffff'
  # When true, faces whose back side points at the camera are painted with the
  # back material / SketchUp's blue back-face color — faithful to the viewport,
  # but reversed faces then show up blue. When false (default), every face uses
  # its front color, so a reversed face can't leave a blue flash in the export.
  # Only relevant when DRAW_FACES is true.
  SHOW_BACK_FACE_COLOR = false
  # Line-weight defaults (px) for the three layers. Users override these in the
  # Settings dialog; values persist via Sketchup.write_default under PREF.
  PREF              = 'SUtoSVG'
  DEFAULT_WIDTH     = 1.5   # single, uniform stroke width (px)
  SVG_MARGIN        = 8.0
  # Hidden-line depth bias, as a fraction of the selection's diagonal. A face
  # must be nearer than an edge by more than this to hide it — stops edges from
  # being over-clipped where they meet a joint (especially in perspective).
  # Increase if joints still show gaps; decrease if hidden lines leak through
  # thin features.
  HLR_BIAS_FRAC     = 0.003
  # After HLR, extend edge tips that were shaved short at a joint until they meet
  # the neighbouring line (within this many pixels). Closes small joint gaps
  # without touching correctly-hidden geometry. Set 0 to disable.
  WELD_GAP_PX       = 12.0
  # Fallback colors when a face has no material and rendering options can't
  # supply one (RGB 0-255).
  DEFAULT_FRONT_RGB = [255, 255, 255].freeze
  DEFAULT_BACK_RGB  = [200, 200, 210].freeze

  # Adapts a Sketchup::View to the plain-array interface SUtoSVG::Hlr expects.
  # Points/vectors crossing this boundary are [x, y, z] Float arrays.
  class ViewAdapter
    def initialize(view)
      @view  = view
      cam    = view.camera
      @persp = cam.perspective?
      @eye   = cam.eye.to_a
      @dir   = cam.direction.to_a
    end

    def project(p)
      sc = @view.screen_coords(Geom::Point3d.new(p[0], p[1], p[2]))
      [sc.x.to_f, sc.y.to_f]
    end

    # Larger == farther from the camera.
    def depth(p)
      (p[0] - @eye[0]) * @dir[0] +
        (p[1] - @eye[1]) * @dir[1] +
        (p[2] - @eye[2]) * @dir[2]
    end

    # Viewing ray through p's screen point: [origin, direction].
    def eye_ray(p)
      if @persp
        [@eye, [p[0] - @eye[0], p[1] - @eye[1], p[2] - @eye[2]]]
      else
        [p, @dir]
      end
    end
  end

  module_function

  # Dev helper: re-`load` every source file so edits take effect without
  # restarting SketchUp. Run `SUtoSVG.reload` in the Ruby Console after editing.
  # `load` (unlike `require`) always re-executes, redefining the methods; the
  # menu's file_loaded? guard keeps it from being added twice.
  def reload
    dir = File.dirname(__FILE__)
    files = %w[collector projector hlr dedup weld shadow svg_writer main].map { |n| File.join(dir, "#{n}.rb") }
    files.each { |f| load(f) }
    "SUtoSVG reloaded #{files.length} files"
  end

  # Diagnostic: prints what's selected and tries two intersection strategies,
  # reporting how many crease edges each produces. Paste the output back.
  # Run: SUtoSVG.reload; SUtoSVG.diagnose   (with your objects selected)
  def diagnose
    model = Sketchup.active_model
    sel = model.selection
    puts '=== SUtoSVG diagnose ==='
    puts "selection size: #{sel.length}"
    sel.to_a.each do |e|
      extra = if e.respond_to?(:definition)
                "def=#{(e.definition.name rescue '?').inspect} " \
                "faces=#{e.definition.entities.grep(Sketchup::Face).length} " \
                "origin=#{e.transformation.origin.to_a.map { |v| v.round(1) }.inspect}"
              else
                ''
              end
      puts "  #{e.class} #{extra}"
    end
    solids = collect_solids(sel)
    puts "leaf solids found (recursed): #{solids.length}"
    solids.each do |defn, tr|
      puts "  def=#{defn.name.inspect} faces=#{defn.entities.grep(Sketchup::Face).length} " \
           "origin=#{tr.origin.to_a.map { |v| v.round(1) }.inspect}"
    end
    return 'need >= 2 solids' if solids.length < 2

    id = Geom::Transformation.new

    a = try_op(model) do |tents|
      solids.each { |defn, tr| tents.add_instance(defn, tr) }
      tents.intersect_with(true, id, tents, id, false, tents.to_a)
      tents.grep(Sketchup::Edge).length
    end
    puts "approach A (instances + intersect_with): #{a.inspect} edges"

    b = try_op(model) do |tents|
      solids.each { |defn, tr| tents.add_instance(defn, tr).explode }
      before = tents.grep(Sketchup::Edge).length
      faces = tents.grep(Sketchup::Face)
      tents.intersect_with(false, id, tents, id, false, faces)
      "#{tents.grep(Sketchup::Edge).length - before} (from #{faces.length} faces)"
    end
    puts "approach B (explode + intersect faces): #{b.inspect}"
    "A=#{a} B=#{b}"
  end

  # Recursively gather every "leaf" solid (a Group/ComponentInstance whose own
  # entities contain faces) reachable from `entities`, each paired with its
  # accumulated WORLD transformation. Descends through nesting groups.
  def collect_solids(entities, tr = Geom::Transformation.new, acc = [])
    entities.each do |e|
      next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      world = tr * e.transformation
      ents = e.is_a?(Sketchup::ComponentInstance) ? e.definition.entities : e.entities
      acc << [e.definition, world] if ents.grep(Sketchup::Face).any?
      collect_solids(ents, world, acc)
    end
    acc
  end

  # Runs a block inside a temp group, aborts afterward so the model is untouched.
  def try_op(model)
    model.start_operation('SUtoSVG diag', true)
    temp = model.active_entities.add_group
    yield temp.entities
  rescue StandardError => e
    "ERROR #{e.class}: #{e.message}"
  ensure
    model.abort_operation
  end

  def export_selection
    model = Sketchup.active_model
    view  = model.active_view
    sel   = model.selection

    if sel.empty?
      UI.messagebox('Nothing selected. Select some geometry and try again.')
      return
    end

    data = Collector.collect(sel)
    has_shadow = !(data[:shadow_faces].empty? && data[:shadow_edges].empty?)
    if data[:faces].empty? && data[:edges].empty? && !has_shadow
      UI.messagebox('The selection contains no faces or edges to export.')
      return
    end

    data[:edges].concat(intersection_edges(model, sel)) if AUTO_INTERSECT

    adapter    = ViewAdapter.new(view)
    bias       = HLR_BIAS_FRAC * world_diagonal(data)
    projected  = project_faces(view, model, adapter, data[:faces])

    # Ground shadow world-space polygons: TIG groups (if any) + our own cast.
    shadow_world = []
    shadow_world += data[:shadow_faces].map(&:loops) if EXPORT_SHADOWS
    shadow_world += compute_cast_shadow(model, data[:faces]) if EXPORT_CAST_SHADOW
    shadow_polys, shadow_lines = build_shadows(view, adapter, shadow_world, data[:shadow_edges])
    has_cast_shadow = shadow_polys.any? || shadow_lines.any?

    # Cast-shadow shapes (shadows landing on other faces), depth-ordered so a
    # shadow on a nearer face draws over one on a farther face. Object faces
    # themselves are not drawn — the output is just lines + shadows.
    fills =
      if DRAW_FACES
        faces_to_svg(projected)
      elsif RECEIVE_ON_FACES && model.shadow_info['DisplayShadows']
        build_fills(view, adapter, model, projected, data[:faces])
      else
        []
      end

    svg_edges = DRAW_EDGES ? build_svg_edges(view, adapter, projected, data[:edges], bias) : []
    Weld.close_gaps(svg_edges, threshold: WELD_GAP_PX) if DRAW_EDGES && WELD_GAP_PX > 0.0

    if fills.empty? && svg_edges.empty? && shadow_polys.empty? && shadow_lines.empty?
      UI.messagebox('Nothing projectable in the current view (is the selection ' \
                    'behind the camera?).')
      return
    end

    # 2D silhouettes of every visible face — used to build masks that hide
    # shadow bleed-through behind objects (ground shadow behind buildings,
    # face-shadows on faces occluded by nearer objects).
    silhouettes = projected.map { |f| f[:loops2d].first }

    svg = SvgWriter.build(fills, svg_edges, margin: SVG_MARGIN,
                          shadow_polys: shadow_polys, shadow_lines: shadow_lines,
                          shadow_fill: blended_shadow_gray, shadow_opacity: SHADOW_OPACITY,
                          ground_mask: silhouettes)

    path = UI.savepanel('Export Selection to SVG', default_dir(model), 'selection.svg')
    return if path.nil? # user cancelled

    path += '.svg' unless path.downcase.end_with?('.svg')
    File.write(path, svg)
    has_shadow = has_cast_shadow || !cast_groups.empty?
    shadow_note = has_shadow ? ', with shadows' : ''
    Sketchup.status_text =
      "SUtoSVG: exported #{svg_edges.length} edge segments#{shadow_note} to #{path}"
  rescue => e
    UI.messagebox("SUtoSVG export failed:\n#{e.message}")
    raise
  end

  # --- projection ----------------------------------------------------------

  # Projects every face once into an intermediate the fill renderer and the
  # HLR occluder set both reuse. Returns an Array of hashes:
  #   { loops2d:, bbox2d:, plane:, depth:, fill: }
  def project_faces(view, model, adapter, world_faces)
    eye = view.camera.eye
    out = []
    world_faces.each do |wf|
      # Perspective safety: drop faces with any vertex at/behind the camera.
      next if wf.loops.flatten.any? { |p| Projector.behind_camera?(view, p) }

      loops2d = wf.loops.map { |loop| loop.map { |p| adapter.project(p.to_a) } }
      out << {
        face:    wf,
        loops2d: loops2d,
        bbox2d:  bbox2d(loops2d),
        plane:   [wf.center.to_a, wf.normal.to_a],
        depth:   Projector.depth(view, wf.center),
        fill:    face_fill(model, wf, eye)
      }
    end
    out
  end

  # Painter's algorithm: draw farthest faces first.
  def faces_to_svg(projected)
    projected
      .sort_by { |f| -f[:depth] }
      .map { |f| SvgWriter::Face.new(f[:loops2d], f[:fill]) }
  end

  # Build the depth-ordered fills: only cast-shadow groups (shadows landing on
  # other faces). Object faces themselves are NOT drawn — the output is just
  # lines + shadows. Faces are still used internally as HLR occluders and to
  # generate the shadow shapes; they just don't appear as filled polygons.
  # Depth-ordered so a shadow on a nearer face draws over one on a farther face.
  def build_fills(view, adapter, model, projected, world_faces)
    items = [] # [depth, tiebreak, drawable]

    if RECEIVE_ON_FACES
      build_face_shadows(view, adapter, compute_face_shadows(model, world_faces)).each do |g|
        # Mask by every strictly-nearer face's silhouette (nearer at centroid
        # depth), excluding the receiver itself. Faces farther than the
        # receiver sit behind it in 3D, so their 2D silhouettes must NOT mask
        # (that erases the shadow — the back of the building projects on top
        # of the visible front in image space).
        mask = projected.select { |f| f[:depth] < g[:depth] - 1e-4 && !f[:face].equal?(g[:recv]) }
                        .map { |f| f[:loops2d].first }
        items << [g[:depth], 1, { polys: g[:polys], mask_loops: mask }]
      end
    end

    items.sort_by { |depth, tie, _| [-depth, tie] }.map { |_, _, item| item }
  end

  # The shadow colour composited over white at SHADOW_OPACITY, used opaque so
  # every shadow reads the same tone and occludes correctly.
  def blended_shadow_gray
    r = SHADOW_FILL[1, 2].to_i(16)
    g = SHADOW_FILL[3, 2].to_i(16)
    b = SHADOW_FILL[5, 2].to_i(16)
    o = SHADOW_OPACITY
    format('#%02x%02x%02x', (r * o + 255 * (1 - o)).round,
           (g * o + 255 * (1 - o)).round, (b * o + 255 * (1 - o)).round)
  end

  # --- edges (with optional hidden-line removal) ---------------------------

  def build_svg_edges(view, adapter, projected, world_edges, bias)
    width = line_width
    edges = []
    world_edges.each do |we|
      next if Projector.behind_camera?(view, we.a) || Projector.behind_camera?(view, we.b)
      edges << Hlr::Edge.new(we.a.to_a, we.b.to_a, nil)
    end
    return [] if edges.empty?

    points_list =
      if USE_HLR
        occluders = projected.map do |f|
          Hlr::Occluder.new(f[:loops2d], f[:bbox2d], f[:plane])
        end
        Hlr.visible_segments(occluders, edges, adapter, bias: bias).map(&:points)
      else
        edges.map { |e| [adapter.project(e.a3), adapter.project(e.b3)] }
      end

    points_list = Dedup.merge_segments(points_list) if DEDUP_OVERLAPS
    points_list.map { |points| SvgWriter::Edge.new(points, width, nil) }
  end

  # --- shadows (from TIG-shadowProjector groups) ---------------------------

  # Project shadow world-polygons (each an Array of loops of Geom::Point3d) into
  # 2D filled polygons. A LINES-type TIG shadow (no faces) falls back to stroked
  # outlines from shadow_edges. Returns [polys, lines].
  def build_shadows(view, adapter, shadow_world, shadow_edges)
    gray = blended_shadow_gray
    polys = []
    shadow_world.each do |loops|
      next if loops.flatten.any? { |p| Projector.behind_camera?(view, p) }
      loops2d = loops.map { |loop| loop.map { |p| adapter.project(p.to_a) } }
      polys << SvgWriter::Face.new(loops2d, gray)
    end

    lines = []
    if polys.empty? # LINES-type shadow: draw the outline edges
      shadow_edges.each do |we|
        next if Projector.behind_camera?(view, we.a) || Projector.behind_camera?(view, we.b)
        lines << [adapter.project(we.a.to_a), adapter.project(we.b.to_a)]
      end
      lines = Dedup.merge_segments(lines) if DEDUP_OVERLAPS && !lines.empty?
    end

    [polys, lines]
  end

  # Built-in cast shadow: project every selected face along the sun's light
  # direction onto a horizontal ground plane. The union of the projected faces
  # (composited at the layer's opacity) is the shadow silhouette. Returns an
  # Array of world polygons (each an Array of loops of Geom::Point3d).
  def compute_cast_shadow(model, world_faces)
    return [] if world_faces.empty?
    si = model.shadow_info
    return [] unless si['DisplayShadows'] # follow SketchUp's shadow toggle
    sun = si['SunDirection']
    dir = [-sun.x, -sun.y, -sun.z] # light travels opposite the sun direction
    return [] unless dir[2] < -1e-6 # sun must be above the horizon to cast down

    ground = ground_z(world_faces)
    out = []
    world_faces.each do |wf|
      loops = wf.loops.map do |loop|
        projected = Shadow.project_loop(loop.map { |p| [p.x, p.y, p.z] }, dir, ground)
        projected && projected.map { |q| Geom::Point3d.new(q[0], q[1], q[2]) }
      end
      out << loops unless loops.include?(nil)
    end
    out
  end

  # For each sun-facing face in the selection, project the other faces (that are
  # on the sun side of it) onto its plane along the light. Returns an Array of
  # { clip: [Geom::Point3d receiving-face loop], polys: [[Geom::Point3d loop]] };
  # the projected polys are clipped to the receiving face when drawn.
  def compute_face_shadows(model, world_faces)
    return [] if world_faces.empty?
    si = model.shadow_info
    return [] unless si['DisplayShadows']
    sun = si['SunDirection']
    dir = [-sun.x, -sun.y, -sun.z]
    sundir = [sun.x, sun.y, sun.z]

    groups = []
    world_faces.each do |recv|
      n = [recv.normal.x, recv.normal.y, recv.normal.z]
      next unless dot3(n, sundir) > 1e-6 # receiver must face the sun
      plane_pt = [recv.center.x, recv.center.y, recv.center.z]

      polys = []
      world_faces.each do |caster|
        next if caster.equal?(recv)
        cn = [caster.normal.x, caster.normal.y, caster.normal.z]
        cc = [caster.center.x, caster.center.y, caster.center.z]
        dist = dot3(n, [cc[0] - plane_pt[0], cc[1] - plane_pt[1], cc[2] - plane_pt[2]])
        next if dist.abs < 1e-4 && dot3(cn, n).abs > 0.999 # skip coplanar casters
        loop3 = caster.loops.first.map { |p| [p.x, p.y, p.z] }
        # Keep only the part of the caster on the sun side of the receiver plane,
        # so casters that straddle it (typical for vertical receivers) still cast.
        clipped = Shadow.clip_to_halfspace(loop3, plane_pt, n)
        next if clipped.length < 3
        proj = Shadow.project_loop_to_plane(clipped, dir, plane_pt, n)
        next if proj.nil?
        polys << proj.map { |q| Geom::Point3d.new(q[0], q[1], q[2]) }
      end
      next if polys.empty?
      clip = recv.loops.first.map { |p| Geom::Point3d.new(p.x, p.y, p.z) }
      groups << { clip: clip, polys: polys, center: recv.center, recv: recv }
    end
    groups
  end

  # Project face-shadow groups to 2D. Returns
  # [{ depth:, clip: [[x,y]], polys: [Face] }] — depth is the receiving face's.
  def build_face_shadows(view, adapter, groups)
    gray = blended_shadow_gray
    out = []
    groups.each do |g|
      next if g[:clip].any? { |p| Projector.behind_camera?(view, p) }
      clip2d = g[:clip].map { |p| adapter.project(p.to_a) }
      polys2d = []
      g[:polys].each do |loop|
        next if loop.any? { |p| Projector.behind_camera?(view, p) }
        # Bake the receiving-face clip in NOW (pure-Ruby 2D clip), so the SVG
        # gets a plain pre-trimmed shape — no clipPath masks to untangle.
        clipped = Shadow.clip_polygon(loop.map { |p| adapter.project(p.to_a) }, clip2d)
        polys2d << SvgWriter::Face.new([clipped], gray) if clipped.length >= 3
      end
      out << { depth: Projector.depth(view, g[:center]), polys: polys2d, recv: g[:recv] } unless polys2d.empty?
    end
    out
  end

  def dot3(a, b)
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
  end

  # Height of the receiving ground plane.
  def ground_z(world_faces)
    return SHADOW_GROUND.to_f unless SHADOW_GROUND == :auto
    minz = nil
    world_faces.each do |wf|
      wf.loops.each { |loop| loop.each { |p| minz = p.z if minz.nil? || p.z < minz } }
    end
    minz || 0.0
  end

  # --- automatic solid-intersection creases --------------------------------

  # Generate the crease edges where separate solids in the selection
  # interpenetrate, WITHOUT modifying the model. SketchUp's Entities#intersect_with
  # is the engine behind Intersect Faces; we run it into a throwaway group inside
  # a start/abort_operation pair, copy the resulting edges to plain world-space
  # WorldEdges, then abort — so nothing is left behind in the model.
  def intersection_edges(model, selection)
    solids = collect_solids(selection) # [[definition, world_transform], ...]
    return [] if solids.length < 2

    result = []
    identity = Geom::Transformation.new
    model.start_operation('SUtoSVG intersect', true)
    begin
      temp  = model.active_entities.add_group
      tents = temp.entities
      # Put a copy of every solid into the temp group AT ITS WORLD POSITION, so
      # they all share one coordinate space (temp itself is identity). This is
      # what makes intersect_with reliable — no cross-space transform juggling.
      solids.each { |defn, tr| tents.add_instance(defn, tr) }
      instances = tents.to_a

      # Compute all mutual surface intersections; the new crease edges are added
      # to tents at the top level (world coords, since transform2 is identity).
      tents.intersect_with(true, identity, tents, identity, false, instances)

      tents.grep(Sketchup::Edge).each do |e|
        result << Collector::WorldEdge.new(e.start.position, e.end.position, [], true)
      end
    ensure
      model.abort_operation # discard the temp group + all generated geometry
    end
    result
  rescue StandardError
    [] # never let intersection trouble abort the whole export
  end

  # --- edge classification -------------------------------------------------

  # --- settings (persisted per-user via Sketchup defaults) -----------------

  def line_width
    Sketchup.read_default(PREF, 'line_width', DEFAULT_WIDTH).to_f
  end

  # Settings dialog: edit the single stroke width; the value is remembered.
  def settings
    result = UI.inputbox(['Line width (px)'], [line_width], 'SUtoSVG — Line Weight')
    return unless result # cancelled
    Sketchup.write_default(PREF, 'line_width', result[0].to_f)
    Sketchup.status_text = "SUtoSVG: line width saved (#{result[0].to_f} px)"
  end

  # Reset saved settings back to their defaults.
  def reset
    Sketchup.write_default(PREF, 'line_width', DEFAULT_WIDTH)
    Sketchup.status_text = "SUtoSVG: settings reset (line width #{DEFAULT_WIDTH} px)"
  end

  # --- color ---------------------------------------------------------------

  # Choose the visible side (front vs back) and return "#rrggbb".
  def face_fill(model, world_face, eye)
    front = if SHOW_BACK_FACE_COLOR
              world_face.normal.dot(world_face.center - eye) < 0.0
            else
              true # always treat the front side as visible
            end

    mat = front ? world_face.front : world_face.back
    mat = world_face.front if mat.nil? # fall back to the painted side, if any
    rgb = material_rgb(mat) ||
          rendering_rgb(model, front) ||
          (front ? DEFAULT_FRONT_RGB : DEFAULT_BACK_RGB)
    to_hex(rgb)
  end

  def material_rgb(mat)
    return nil if mat.nil? || mat.color.nil?
    mat.color.to_a[0, 3]
  end

  def rendering_rgb(model, front)
    opts = model.rendering_options
    key = front ? 'FaceFrontColor' : 'FaceBackColor'
    c = opts[key]
    c.nil? ? nil : c.to_a[0, 3]
  rescue StandardError
    nil
  end

  def to_hex(rgb)
    format('#%02x%02x%02x', rgb[0].to_i, rgb[1].to_i, rgb[2].to_i)
  end

  # --- helpers -------------------------------------------------------------

  # World-space bounding-box diagonal of the whole selection (model units).
  def world_diagonal(data)
    min = [Float::INFINITY, Float::INFINITY, Float::INFINITY]
    max = [-Float::INFINITY, -Float::INFINITY, -Float::INFINITY]
    add = lambda do |p|
      3.times do |i|
        v = p[i]
        min[i] = v if v < min[i]
        max[i] = v if v > max[i]
      end
    end
    data[:faces].each { |wf| wf.loops.each { |loop| loop.each { |pt| add.call(pt) } } }
    data[:edges].each { |we| add.call(we.a); add.call(we.b) }
    return 0.0 if min[0] == Float::INFINITY
    Math.sqrt((max[0] - min[0])**2 + (max[1] - min[1])**2 + (max[2] - min[2])**2)
  end

  def bbox2d(loops2d)
    min_x = min_y =  1.0 / 0.0
    max_x = max_y = -1.0 / 0.0
    loops2d.each do |loop|
      loop.each do |(x, y)|
        min_x = x if x < min_x
        min_y = y if y < min_y
        max_x = x if x > max_x
        max_y = y if y > max_y
      end
    end
    [min_x, min_y, max_x, max_y]
  end

  def default_dir(model)
    model.path.empty? ? nil : File.dirname(model.path)
  end
end

# --- toolbar + menu --------------------------------------------------------
unless file_loaded?(__FILE__)
  icons = File.join(File.dirname(__FILE__), 'icons')

  export_cmd = UI::Command.new('Run') { SUtoSVG.export_selection }
  export_cmd.small_icon = export_cmd.large_icon = File.join(icons, 'export.svg')
  export_cmd.tooltip = 'Export Selection to SVG'
  export_cmd.status_bar_text = 'Export the current selection to an SVG line drawing'

  settings_cmd = UI::Command.new('Set Line Weight') { SUtoSVG.settings }
  settings_cmd.small_icon = settings_cmd.large_icon = File.join(icons, 'settings.svg')
  settings_cmd.tooltip = 'Set Line Weight'
  settings_cmd.status_bar_text = 'Set the stroke width for the export'

  reset_cmd = UI::Command.new('Reset') { SUtoSVG.reset }
  reset_cmd.small_icon = reset_cmd.large_icon = File.join(icons, 'reset.svg')
  reset_cmd.tooltip = 'Reset settings to defaults'
  reset_cmd.status_bar_text = 'Reset SUtoSVG settings to their defaults'

  toolbar = UI::Toolbar.new('SUtoSVG')
  toolbar.add_item(export_cmd)
  toolbar.add_item(settings_cmd)
  toolbar.add_item(reset_cmd)
  toolbar.restore

  # Arkido > SUtoSVG > Run / Set Line Weight / Reset (a shared "Arkido" submenu
  # under Extensions; $arkido_menu lets sibling Arkido tools reuse the submenu).
  $arkido_menu ||= UI.menu('Extensions').add_submenu('Arkido')
  sutosvg_menu = $arkido_menu.add_submenu('SUtoSVG')
  sutosvg_menu.add_item(export_cmd)
  sutosvg_menu.add_item(settings_cmd)
  sutosvg_menu.add_item(reset_cmd)

  file_loaded(__FILE__)
end
