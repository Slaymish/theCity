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
- Setting `renderingEffects.customPostProcessing` in a `RealityView` traps in `ARView.renderCallbacks.setter`, including on macOS 27 when the effects are updated, so `SceneGrade` only runs in offscreen renders.
- Don't wrap `RealityView` in `.accessibilityElement(children: .contain)`, because it stops the scene rendering. VoiceOver children go on a transparent overlay instead.
- `Worker.headPosition` and `OfficeScene.overviewPose` use world positions (`relativeTo: nil`). Scale or move the city, never the building root.
- A rig that follows a scaled scene needs `CameraRig.frame` set, and its camera entity must not be parented under the scaled root.
- Every `OfficeScene` adds its own sun. In the building view only one storey's sun is enabled.
- Check visual changes with an offscreen render (see CLAUDE.md), not by driving the live window.
- The iPhone app compiles the scene files listed under `TheCityCompanion` in `project.yml`. In those, use `LaunchArgument`, not `RunController`, `CityStore` or `Preferences`, and fence AppKit-only calls with `#if os(macOS)`.
- Build boxes with `ModelLibrary.box(width:height:depth:cornerRadius:)` and PBR materials with `ModelLibrary.material(_:roughness:emissive:)`, never `MeshResource.generateBox` or a fresh `PhysicallyBasedMaterial`, because making them is the slow part of building a scene. Collision shapes are unaffected.
- A new repeating sign view conforms to `BillboardKeyed`, and its key includes every input that changes how it draws (use `NSColor.key(dark:)` for colours). A panel redrawn often keeps its `TextureResource` and updates through `LivePanel.show(_:on:reusing:)`, not a new material each tick.
- Per-frame code (`Worker` pose and bend, `Horizon.place`, `CameraRig`) writes an entity's transform only when the value has changed, since every robot on every storey runs each frame.
- Saved types (`CityStore.Floor`, `CityStore.Building`, `JobRecord`, `JobTotals`, `HistoryEntry`) use synthesised `Codable`, which rejects a file missing any non-optional key, even one with a default. Make new fields optional, and read and write these files only through `DataFiles`.
