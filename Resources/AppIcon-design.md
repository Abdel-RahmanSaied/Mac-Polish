# Mac Polish app icon

Generated with the built-in image_gen tool. Master: AppIcon.png, with transparent margins. AppIcon.iconset contains the macOS 1x and 2x sizes; AppIcon.icns is copied into the app bundle by Scripts/build-app.sh. CFBundleIconFile selects it for Finder, Dock and application panels. The sidebar loads the raw icon resource to avoid the system's legacy-icon frame, and scales it by 1.25 to fill its 44-point slot without the Dock artwork's transparent margins.

Final generation prompt:

> Use case: logo-brand. Asset type: production macOS app icon for Mac Polish, a personal Mac storage cleaner and memory monitor. Create ONE square app icon only, no presentation board. Premium native macOS style, a softly rounded cyan-to-deep-blue squircle tile, subtle dimensional glass and enamel, containing a bold polished silver storage-disc symbol with a dark blue center and one crisp white four-point cleaning sparkle overlapping its upper-right rim. Simple strong silhouette, elegant restrained details, balanced optical centering, legible at 32 pixels. Tile occupies about 82% of square canvas, standard generous macOS icon margins. Soft tight contact shadow under tile. Straight-on orthographic view. Clean transparent background outside tile; actual alpha transparency, no checkerboard painted into artwork. No text, letters, numbers, watermark, Apple logo, broom, tiny UI details, extra objects or frame. High-resolution square raster.

The generated master is resized with sips and packaged with iconutil; the design is preserved.

The bundle declares the complete `AppIcon.icns` filename. At launch and reopen, the app explicitly sets `NSApplication.applicationIconImage` from that resource so a cached generic Dock tile does not persist. The installer refreshes only the installed bundle's Launch Services registration.
