---
description: Blender pipeline, sounds and bundled asset files
paths:
  - "Assets/Pipeline/**"
  - "App/Models/**"
  - "App/Sounds/**"
  - "App/Environment/**"
---

# Assets

- Models are built by `Assets/Pipeline/*.py` (Blender 5.1) from the KayKit sources in `Assets/Vendor`, and the output goes to `App/Models`. Change the script, not the output.
- Blender 5.1's USD export option names differ from older docs. Copy them from `convert.py`.
- zsh doesn't split an unquoted `$list`, so use arrays when passing many files to Blender. Brace variables (`${d}`) inside ffmpeg filter strings, because zsh reads `$d[a1]` as a subscript.
- Kenney ships OGG, which AVFoundation can't play. Convert with ffmpeg and credit the file in `App/Sounds/SOUND-CREDITS.md`.
- Credit files need distinct names (`MODEL-CREDITS.md`, `SOUND-CREDITS.md`, …). Two files with the same name stop the bundle's resource copy.
