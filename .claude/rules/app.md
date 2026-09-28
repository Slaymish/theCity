---
description: SwiftUI, RealityKit and theming conventions for the app target
paths:
  - "App/**/*.swift"
  - "App/Brands/**"
---

# App

- Colours come from `Palette` in `App/Theme.swift`, which reads the active brand's tokens (`App/Brands/<id>/brand.json` → `Brand.swift`). Never write a colour literal elsewhere. A new colour means a new token in every brand, so ask first.
- Sizes, spacing, timings and colours need approval from the owner. Ask before picking one.
- The target is macOS 26. `BloomComponent` and `EnvironmentResource(equirectangular:options:)` need macOS 27.
- Don't wrap `RealityView` in `.accessibilityElement(children: .contain)`, because it stops the scene rendering. VoiceOver children go on a transparent overlay instead.
- `Worker.headPosition` and `OfficeScene.overviewPose` use world positions (`relativeTo: nil`). Scale or move the city, never the building root.
- A rig that follows a scaled scene needs `CameraRig.frame` set, and its camera entity must not be parented under the scaled root.
- Every `OfficeScene` adds its own sun. In the building view only one storey's sun is enabled.
- Check visual changes with an offscreen render (see CLAUDE.md), not by driving the live window.
- The iPhone app compiles the scene files listed under `TheCityCompanion` in `project.yml`. In those, use `LaunchArgument`, not `RunController`, `CityStore` or `Preferences`, and fence AppKit-only calls with `#if os(macOS)`.
