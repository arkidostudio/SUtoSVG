# SUtoSVG

A SketchUp extension that exports the **current selection** to an **SVG** file,
projected exactly as it appears in the viewport — using the live camera
(position, angle, and perspective/parallel mode).

SketchUp Pro's built-in *File → Export → 2D Graphic* can produce vector output,
but it exports the **whole view** and never SVG. SUtoSVG exports **just your
selection** and writes **SVG**.

## How it works

1. Walks your selection recursively, descending into groups/components and
   applying their transformations, to gather every face and edge in world space.
2. Projects each vertex to 2D screen pixels via `view.screen_coords`, which uses
   the active camera — so the output matches the current viewport view.
3. Runs **hidden-line removal** on the edges: each edge is clipped against every
   face using 2D silhouette intersection plus a 3D depth test, so only the parts
   of an edge that aren't behind a nearer face are drawn. Holes and edges that
   cross a face's plane are handled exactly.
4. Classifies each edge as a **profile** (outline/silhouette) or interior edge
   and strokes them at separate weights, like SketchUp's Profiles.
5. Optionally fills faces (off by default — see `DRAW_FACES`). Even when not
   drawn, faces still act as occluders for step 3.
6. Crops the canvas to the selection's bounding box and writes an SVG.

## Install

**Option A — Extension Manager (recommended)**

1. Zip the *contents* of the `src/` folder (so `su_to_svg.rb` and the
   `su_to_svg/` folder are at the zip root), then rename the `.zip` to
   `SUtoSVG.rbz`.
   ```
   cd src && zip -r ../SUtoSVG.rbz su_to_svg.rb su_to_svg
   ```
2. In SketchUp: **Extensions → Extension Manager → Install Extension**, pick
   `SUtoSVG.rbz`.

**Option B — copy into the Plugins folder**

Copy `src/su_to_svg.rb` and the `src/su_to_svg/` folder into your SketchUp
Plugins folder:

- macOS: `~/Library/Application Support/SketchUp 20XX/SketchUp/Plugins/`
- Windows: `%AppData%\SketchUp\SketchUp 20XX\SketchUp\Plugins\`

Restart SketchUp.

## Use

1. Select the geometry you want to export.
2. Orbit/zoom to the view you want.
3. Click **Run** on the *SUtoSVG* toolbar (or **Extensions ▸ Arkido ▸ SUtoSVG ▸
   Run**).
4. Choose a save location. Open the `.svg` in a browser, Illustrator, Inkscape,
   or Figma.

### Line weight

All edges are drawn at a single, uniform stroke width. Set it via the
**Settings** (sliders) toolbar button, or **Extensions ▸ Arkido ▸ SUtoSVG ▸ Set
Line Weight**. The value is remembered between sessions (default 1.5 px).

> The toolbar appears after SketchUp loads the extension — if you just installed
> or symlinked it into a running session, **restart SketchUp once** to get the
> toolbar. After that, `SUtoSVG.reload` in the Ruby Console is enough for code
> edits.

## Configuration

Edit the constants at the top of `src/su_to_svg/main.rb`:

- `DRAW_FACES` — draw filled faces (default `false` = pure line drawing). Faces
  still occlude hidden edges even when not drawn. Set `true` for filled output.
- `DRAW_EDGES` — draw edges (default `true`).
- `USE_HLR` — hidden-line removal on edges (default `true`). Set `false` for a
  fast X-ray wireframe that draws every edge unclipped.
- `DEDUP_OVERLAPS` — merge coincident/overlapping collinear lines into one
  (default `true`), so shared edges of objects that touch (e.g. a box sitting on
  another) don't export as doubled lines.
- `AUTO_INTERSECT` — auto-generate the crease edges where separate solids
  interpenetrate (default `true`), using SketchUp's own intersection engine in a
  throwaway group that is discarded — **the model is not modified**. Lets you
  skip running *Intersect Faces* by hand. Note: if you've *already* run Intersect
  Faces on the model, turn this off (or remove the manual edges) to avoid
  doubled lines.
- `HLR_BIAS_FRAC` — depth bias for HLR, as a fraction of the selection's
  diagonal (default `0.003`). A face must be nearer than an edge by more than
  this to hide it, which stops edges from being over-clipped where they meet a
  joint (most visible in **perspective**). Increase if joints still show small
  gaps; decrease if hidden lines start leaking through thin features.
- `WELD_GAP_PX` — after HLR, extend edge tips that were shaved short at a joint
  until they meet the neighbouring line, within this many pixels (default
  `12.0`). Only extends an edge along its own axis, so it never creates spurious
  connections. Set `0` to disable.
- `DEFAULT_WIDTH` — the starting uniform stroke width (px). Just a default; the
  live value is set in the **Settings** dialog and persisted per-user.
- `SHOW_BACK_FACE_COLOR` — only relevant when `DRAW_FACES` is `true`. When
  `true`, back-facing faces use SketchUp's blue back-face color (faithful to the
  viewport); default `false` uses the front color so **reversed faces can't
  leave blue flashes**. (You can also fix the source with *Reverse Faces*.)
- `SVG_MARGIN` — padding around the content.
- `DEFAULT_FRONT_RGB` / `DEFAULT_BACK_RGB` — fallback colors for unpainted faces.

## Testing

The SVG generator and the hidden-line-removal core are pure Ruby (no SketchUp
dependency) and unit-tested:

```
ruby test/svg_writer_test.rb   # SVG builder unit tests
ruby test/hlr_test.rb          # hidden-line-removal unit tests
ruby test/make_sample.rb       # writes sample_cube.svg (filled cube)
ruby test/make_hlr_sample.rb   # writes cube_hlr.svg + cube_wire.svg (HLR vs wireframe)
```

`test/make_hlr_sample.rb` is a good sanity check: it projects a cube
isometrically and confirms HLR removes the three hidden back edges (12 → 9
segments).

## Known limitations

- **Face occlusion is approximate.** Faces are ordered back-to-front by centroid
  depth (painter's algorithm), not a per-pixel z-buffer, so interpenetrating or
  mutually-overlapping faces can occasionally sort wrong. (Edge HLR is exact per
  edge/face pair; this only affects the filled polygons.)
- **HLR is O(edges × faces).** Every edge is tested against every face, so very
  large selections (many thousands of faces) can be slow. A screen-space
  bounding-box pre-reject keeps typical selections fast; set `USE_HLR = false`
  for an instant wireframe.
- **Soft/smooth edges are still drawn** (clipped). Curves therefore look
  faceted; hide their segmentation in SketchUp if you want smooth silhouettes.
- **Textures flatten** to their material's average color (SVG can't easily embed
  the texture).
- **Perspective clipping:** faces/edges with any vertex at or behind the camera
  are dropped (rare for a framed selection).

These are the natural next upgrades if you want higher fidelity later.
```
