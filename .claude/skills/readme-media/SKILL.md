---
name: readme-media
description: Create, refresh or polish The City's README GIFs and app icon. Scenes are scripted in App/ReadmeReel.swift, rendered offscreen frame by frame, and encoded by Tools/Dev/readme-gifs.sh. Use when asked to update, improve or re-render the README GIFs, reels, media, screenshots or app icon, to show a new feature in them, or to add a new reel.
argument-hint: "[what to change, e.g. 'show the hiring badges' or 'polish the city reel']"
---

# README media for The City

The README's GIFs are real scenes played from a script, not screen recordings, so they stay reproducible and can be changed in code. The app icon is rendered the same way from the city's own models.

| Output | Source | Regenerate |
| --- | --- | --- |
| `Docs/Media/city.gif` | `ReadmeReel.city` | `Tools/Dev/readme-gifs.sh` |
| `Docs/Media/office.gif` | `ReadmeReel.office` | `Tools/Dev/readme-gifs.sh` |
| `App/Assets.xcassets/AppIcon.appiconset/*` | `IconRenderer.render` | see "App icon" below |

## How a reel works

- `TheCity -render-reel <name> <dir> [-fps n] [-theme light|dark] [-workspace <dir>]` dispatches from `AppDelegate` (`App/Attention.swift`) to `ReadmeReel.run`, writes `frame-00000.png`… at 1600 × 1000, then exits.
- Each reel builds real scene objects (`World`, `CityScene`, `BuildingScene`, `OfficeScene`) with sample data and passes `record` a list of **cues**: `(at: seconds, run: closure)`. Cues call the same APIs the app uses: `scene.apply([OfficeEvent…])`, `focus(room:)`, `showOverview()`, `world.enter`, `building.enter(floor:)`, `city.riseBuilding`, `flyTowards`.
- `record` steps the scene in simulated time (two half-steps a frame) and captures with one reused `FrameRecorder` (`App/OffscreenRenderer.swift`). The `overlay` closure composites SwiftUI views such as `DeskCard` onto frames with `OffscreenRenderer.composite(_:card:leadingAt:)`. Pre-render the card once.
- The script renders at 20 fps, then ffmpeg drops to each reel's GIF rate (`fps` map in the script), scales to 800 px wide, builds a 128-colour palette, and gifsicle compresses with `--lossy=40`.

## Workflow

1. **Find out what to change.** For a feature, read its code to find the events and APIs that show it. Plan the timeline as a list of beats (what the viewer sees, and for how long) before writing cues. Ask the owner in one batch for anything that's their call: which theme, which reel, the length, and any on-screen text.
2. **Edit `App/ReadmeReel.swift`.** For a new reel, add a `case` to `run`, a private function, the name in the script's `for reel in …` loop and `fps` map, and an image with descriptive alt text in `README.md`.
3. **`make build`**, then run a quick check at a low frame rate and look at a contact sheet before a full render:
   ```sh
   S=<scratchpad>; B=build/Build/Products/Debug/TheCity.app/Contents/MacOS/TheCity
   perl -e 'alarm 300; exec @ARGV' $B -render-reel office $S/t -fps 2 -theme light -workspace "$PWD/SampleWorkspace"
   magick montage -font /System/Library/Fonts/Supplemental/Arial.ttf $S/t/frame-*.png -tile 6x -geometry 400x250+2+2 $S/sheet.png
   ```
   Then Read the sheet. For full-rate frames, sample every Nth with `$(ls $S/t/*.png | awk 'NR%12==1')`.
4. **`Tools/Dev/readme-gifs.sh`** renders and encodes both reels into `Docs/Media` and prints their sizes.
5. **Check the GIFs themselves**, because optimised frames are deltas: `magick Docs/Media/office.gif -coalesce miff:- | magick 'miff:-[95]' $S/f.png`. Look at card text legibility at 800 px, banding, and anything cut off.
6. Report the sizes and every timing, framing or colour you chose, and flag them as unapproved. Commit only when asked.

## Budgets

- Keep each GIF under about 8 MB. Before this skill existed, the city reel came to 7.2 MB at 12 fps and the office reel to 3.3 MB at 15 fps.
- Camera motion and trees are what cost bytes. To shrink a GIF, try these in order: shorten or hold still shots, lower the fps, raise `--lossy`, reduce width to 720. Dithering adds about 5%. Leaving it off causes slight banding on flat surfaces.
- One theme (light) is published. A dark variant through `<picture>`/`prefers-color-scheme` would double the weight, so ask first.

## App icon

`IconRenderer.render` draws a brick `Facade.tower` on a `base` tile with a bush and the robot, under an orthographic camera. It fills a squircle (inset 100/1024, radius 22.5%) in the light `background` token. To regenerate:

```sh
B=build/Build/Products/Debug/TheCity.app/Contents/MacOS/TheCity; I=App/Assets.xcassets/AppIcon.appiconset
perl -e 'alarm 120; exec @ARGV' $B -render-icon $S/icon.png
for n in 16 32 128 256 512; do sips -z $n $n $S/icon.png --out $I/icon_${n}x${n}.png; d=$((n*2)); sips -z $d $d $S/icon.png --out $I/icon_${n}x${n}@2x.png; done
```

Check it at 512 px and at 32 px (`magick icon.png -resize 32x32 -scale 128x128 small.png`). Then `make install` so a relaunched app shows it.

## Traps already found

- Anything driven by `Task.sleep` doesn't run in the synchronous frame loop: `World.leave`'s finish, `OfficeScene.focus`'s 2° pitch settle, `Sound.play(after:)`. Use cues for timing, and avoid `world.leave(animated: true)` unless you add a sim-time path for it.
- `ImageRenderer` draws AppKit-backed controls, such as `.buttonStyle(.link)`, as a yellow placeholder with a ⊘ symbol. The office reel puts its dummy `RunController` in Auto mode (`setPermissionMode(.auto)`) so `DeskCard` hides the "switch to Auto" link. Watch for the same problem in any new SwiftUI overlay.
- A `RunController` created for a reel never starts `claude`, so it costs nothing. Don't call `newJobOnFloor` in a reel.
- The office overview is framed with room for the live HUD, so the reel tightens it with `camera.overview.distance *= 0.72`. The card is rendered at `scale = 1.5` so it survives the downscale to 800 px.
- `building.show` at the moment of entering flashes the tower labels for a frame over the façade. It's barely visible, but fix it here first if you're polishing.
- Robot poses: a raised arm hides behind the head when seen from the front, and a small robot's wave doesn't read. Idle updates turn the head, so for stills either don't call `worker.update` or pass `reduceMotion: true`. Props behind the tower (the camera looks from +x, +z) are hidden.
- There's no `timeout` on this Mac, so use `perl -e 'alarm N; exec @ARGV' …`. In zsh, brace variables inside ffmpeg filter strings (`${3}`, not `$3:`), or zsh reads them as modifiers.
- The scene sizes, lens and colours come from the app, so never hard-code colours in a reel. Use `Palette` tokens (owner's rule).
