# SUtoSVG — project notes for Claude

SketchUp extension that exports the current selection to an **SVG line drawing**
(with hidden-line removal, uniform stroke, and sun-shadow rendering) exactly as
seen through the active camera.

Menu path: **Extensions ▸ Arkido ▸ SUtoSVG ▸ Run / Set Line Weight**.

## Dev workflow

- **`src/su_to_svg/` is symlinked into SketchUp 2026's Plugins folder**, so edits
  in `src/` are live. Reload without restarting:
  ```ruby
  SUtoSVG.reload; SUtoSVG.export_selection
  ```
- **Restart SketchUp** only after touching `src/su_to_svg.rb` (registrar) or the
  toolbar wiring at the bottom of `main.rb`. Reload handles everything else.
- Rebuild the `.rbz` for distribution:
  ```
  (cd src && zip -r ../SUtoSVG.rbz su_to_svg.rb su_to_svg -x '*.DS_Store')
  ```
- Ruby compat: SketchUp's embedded Ruby is old — **no `filter_map`, no endless
  methods (`def f = ...`)**, and force floats on divisions (`x.to_f / y`) to
  avoid integer-truncation bugs.

## Repo layout

```
src/su_to_svg.rb           registrar (loads main.rb, adds submenu + toolbar)
src/su_to_svg/main.rb      pipeline: collect -> project -> HLR -> weld -> dedup -> shadows -> SVG
src/su_to_svg/collector.rb walks selection, resolves world coords, tags shadow groups
src/su_to_svg/projector.rb thin wrapper on view.screen_coords + depth/frustum
src/su_to_svg/hlr.rb       hidden-line removal (edge clipping vs face silhouettes)
src/su_to_svg/dedup.rb     merges coincident collinear line segments (touching objects)
src/su_to_svg/weld.rb      closes small joint gaps by extending edge tips along-axis
src/su_to_svg/shadow.rb    3D projection of loops onto planes; half-space clipping
src/su_to_svg/svg_writer.rb pure-Ruby SVG builder (only file with the SVG string logic)
src/su_to_svg/icons/       toolbar SVG icons (export, settings, reset)
test/*_test.rb             pure-Ruby unit tests, run with `ruby test/<name>_test.rb`
```

## Pipeline (in `main.rb::export_selection`)

1. **Collect** faces + edges from the selection (`Collector.collect`). Recurses
   through groups/components; auto-intersect creases between separate solids.
2. **Project** each face and camera-depth via `ViewAdapter` + `Projector`.
3. **Edges → HLR → weld → dedup → single-width polylines** grouped in
   `edges-<weight>` layers.
4. **Shadows** (when `model.shadow_info['DisplayShadows']`):
   - Ground shadow: project every face along the sun onto the base plane, merge
     into one `<path>` via nonzero union.
   - Face shadows: project casters onto each sun-facing receiver, clipped to
     that face's plane and pre-clipped to sun-side half-space.
   - **No face fills.** The output is lines + shadows only — the viewer's white
     canvas reads as the object's lit faces. To keep shadows from bleeding
     through the (transparent) building, each shadow carries an SVG `<mask>`:
     ground shadow masked by every object silhouette, each face-shadow masked
     by strictly-nearer face silhouettes. `<mask>` (grayscale, raster union)
     avoids the `<clipPath>+evenodd` overlap-toggle bug.
5. **SVG writer** emits masks in `<defs>`, then ground shadow, then face
   shadows, then edges.

## Output structure

Every export has these top-level `<g>` layers (Inkscape/Illustrator recognise
them as layers):

- `shadow-ground` — the ground shadow (one merged `<path>`, clipped by all
  object silhouettes so it doesn't bleed through them).
- `shadow-faces` — shadows landing on other faces (one merged `<path>` per
  receiver, each clipped by its nearer occluders).
- `edges-thin`, `edges-thick` — the line drawing (per-weight layers).

**Object faces are NOT drawn as fills.** The output is strictly lines +
shadows; the viewer's white canvas stands in for the object's lit faces.
Set `DRAW_FACES = true` to emit real face colours instead.

## Options (constants at the top of `main.rb`)

Only edit these if the default behaviour is wrong. Persisted user settings
(currently just line width) live under `Sketchup.write_default('SUtoSVG', ...)`.

- `DRAW_FACES` — off; faces are only used internally.
- `USE_HLR`, `AUTO_INTERSECT`, `DEDUP_OVERLAPS` — safe defaults on.
- `EXPORT_SHADOWS`, `EXPORT_CAST_SHADOW`, `RECEIVE_ON_FACES` — shadow toggles.
- `HLR_BIAS_FRAC` (0.003) — depth bias so joint tips don't get over-clipped.
- `WELD_GAP_PX` (12) — max joint gap the weld pass closes.
- `SHADOW_FILL`, `SHADOW_OPACITY` — used to compute `blended_shadow_gray`, the
  pre-composited fill actually used at full opacity (so ground + face shadows
  read the same tone).

## Firm constraints

- **No SketchUp-engine polygon boolean at export time.** Any code that
  materialises coplanar faces from projected loops crashed SketchUp — don't add
  it back. The union of shadow pieces is a **compound `<path>` with
  `fill-rule="nonzero"`**, not a real Ruby polygon union. Partial occlusion is
  done via SVG `<clipPath>` with `clip-rule="evenodd"`, not a Ruby boolean.
- **All `.rb` under `src/su_to_svg/` except `main.rb` must stay pure Ruby**
  (no SketchUp calls). This is what lets the tests run under system Ruby.
- **Ground shadow doubles-up if the model already has manual `Intersect Faces`
  edges.** `AUTO_INTERSECT` generates them non-destructively; either use auto
  or clear manuals — not both.
- **Degenerate (edge-on) geometry is culled in the writer** — don't undo the
  `MIN_AREA` check; it removes a huge amount of junk when the camera is
  orthogonal to a face.

## Testing

Run all pure-Ruby tests:

```
for t in svg_writer hlr weld dedup shadow; do ruby test/${t}_test.rb; done
```

`shadow.rb`, `hlr.rb`, `dedup.rb`, `weld.rb`, `svg_writer.rb` are all pure Ruby
and covered by unit tests. `main.rb`, `collector.rb`, `projector.rb` need
SketchUp — verify those by exporting from the running app.

Sample SVG generators (also pure Ruby):

```
ruby test/make_sample.rb        # a small cube via projector
ruby test/make_hlr_sample.rb    # HLR against a cube
```

Both write into the repo root; `.gitignore` keeps them out of commits.

## Known open threads

- **Shadow bleed-through inside interior extrusions** — a face whose caster's
  outer loop encloses the receiver but whose *inner* loops don't project. The
  writer would need to project all loops of a multi-loop caster, not just
  `caster.loops.first`. Not yet fixed.
- **Sun-side clipping is per-caster half-space**, not full 3D occlusion — a
  caster geometrically shadowed by another caster still contributes. Real 3D
  shadow HLR would need a proper shadow-volume test.

## Committing

`origin` is `https://github.com/arkidostudio/SUtoSVG` on `main`. Commit style
matches the repo's history (subject + bullet body). Only push when explicitly
asked.
