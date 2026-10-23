# Windows assets

- `GoPray.ico`: app icon (concept C), 256/64/48/32/24/16.
- `app-icon-1024.png`: source PNG for installer art.
- `tray-black-for-light-taskbar.ico` / `tray-white-for-dark-taskbar.ico`: the mihrab tray icon (same glyph as the Mac menu bar icon), 16/20/24/32. Switch on the taskbar theme (SystemUsesLightTheme).

Scene stills are not shipped as files: render them at runtime from the scenes like the Mac `SceneStill.swift` does (per-prayer crop rects there), cached per app version.
