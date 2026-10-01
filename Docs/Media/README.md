# README media

These GIFs use the app's real scenes and controls. The city and office jobs are scripted examples run through the stream reducer; rendering never starts Claude or spends tokens.

## Art direction

Warm miniature city: evening light, readable robot expressions, timber floors, gentle camera moves, and a clear view of the work. Colours come from the existing brand palette.

| Reel | Beats | Duration | Width | Frame rate | Local hour |
| --- | --- | --- | --- | --- | --- |
| `showcase.gif` | Varied building heights, traffic through the centre, slow camera sway, dissolve back to the opening | 8 s | 800 px | 12 fps | 18:33 |
| `city.gif` | Welcome → construction → reception → working floor | 10.5 s | 800 px | 15 fps | 18:09 |
| `office.gif` | Assign work → tools → approval close-up → hand back → delivery | 13 s | 880 px | 20 fps | 18:12 |

The showcase camera eases in for 1.5 seconds, holds the view while traffic moves, then returns over 1.5 seconds. A 0.6-second dissolve closes the traffic loop. The office overview is closer than before, with a 2.4-second approval-card hold and 3.7 seconds for the delivery. The city prepares and enters the building in the same cue; the building hides its floating signs until it has risen so they cannot show through the facade.

## Regenerate

```sh
make build
Tools/Dev/readme-gifs.sh        # all three, or pass showcase / city / office
Tools/Dev/readme-icons.sh      # Mac sizes and an opaque iPhone master
make install                  # include the new icons in the installed app
```

Reels render at 1600 × 1000 with medium edge smoothing and miniature focus, plus the offscreen colour grade. The HUD is composited after those effects so its text stays sharp. Simulation steps stay at 1/60 second or smaller, even for a 2 fps contact sheet.

GIFs use 192 colours (128 for the city tour), light ordered dithering and per-reel compression. Each reel is also written as an H.264 MP4 (`<reel>.mp4`, CRF 23, `veryslow`, `-tune animation`, no audio, faststart) from the same source frames, at about a tenth of the GIF's size. The script refuses to replace a published GIF if the new file exceeds 8 MiB and keeps the source frames for another encoding pass. Inspect coalesced frames from the final GIF, including the approval text and both ends of the showcase loop.

## Icons

`App/IconRenderer.swift` renders the brick office and robot with warm light, contact shadows and a cream-to-peach backdrop. The robot is enlarged for a clearer silhouette at Dock sizes. The Mac set has a rounded tile and transparent margin; the iPhone image fills the square because iOS applies its own mask. Both are generated from the same scene. Check the Mac icon at 32 px as well as 512 px.

The source of the scripted timelines is `App/ReadmeReel.swift`; export settings live in `Tools/Dev/readme-gifs.sh`.
