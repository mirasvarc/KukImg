# Kuk

A fast, native macOS image viewer built with SwiftUI. Designed for flipping through large folders of photos with zero friction — thumbnails come from the system QuickLook cache, everything decodes off the main thread, and stale work is cancelled the moment you move on.

<!-- Add a screenshot: docs/screenshot.png -->

## Features

- **Fast grid browsing** — lazy grid with quantized thumbnail sizes, adjustable via a toolbar slider; thumbnails are served from a memory cache backed by QuickLook (the same cache Finder uses) with an ImageIO fallback
- **Instant navigation** — neighboring images are prefetched around the selection, and prefetches/decodes that fall out of view are cancelled, so holding an arrow key stays smooth even in huge folders
- **Detail view** — fit-to-window by default, pinch to zoom, double-click to toggle fit ↔ 100 %, EXIF orientation handled correctly
- **Fullscreen mode** — distraction-free viewing with a slideshow (next image preloaded, cursor auto-hidden)
- **Metadata panel** — dimensions, camera, lens, ISO, shutter, aperture, focal length, GPS from EXIF
- **Filter & sort** — live filename filter, six sort orders, optional recursive folder scan
- **Live folder watching** — files added or removed in Finder show up automatically
- **Finder integration** — drag & drop a folder (or a single image), reveal in Finder, copy, move to Trash
- **Recent folders** — sidebar and File → Open Recent, restored across launches via security-scoped bookmarks (the app is sandboxed)

## Keyboard shortcuts

| Key | Action |
|---|---|
| ← → ↑ ↓ | Move selection (grid: by row/column) |
| Home / End | First / last image |
| Return / Space | Open fullscreen |
| Esc | Leave fullscreen |
| Space / P (fullscreen) | Toggle slideshow |
| ⌫ (fullscreen), ⌘⌫ | Move to Trash |
| ⌘O | Open folder |
| ⇧⌘C | Copy image |
| ⇧⌘R | Show in Finder |

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 or later to build

## Building

```bash
git clone https://github.com/mirasvarc/KukImg.git
cd KukImg
open KukImg.xcodeproj
```

Build and run the `KukImg` scheme (⌘R). No dependencies — the app uses only system frameworks (SwiftUI, AppKit, QuickLookThumbnailing, ImageIO).

## Architecture notes

- `AppModel` — single `@Observable` model: folder scanning, selection, filtering, sorting, folder watching (DispatchSource), prefetch orchestration
- `ThumbnailCache` — actor with separate NSCaches for grid thumbnails and large previews; requests are quantized into size buckets and fully cancellable
- `FullImageCache` — small LRU of fully decoded images so stepping back is instant
- `MetadataCache` — deduplicated EXIF reads shared by the status bar and info panel
- All decoding runs off the main thread and respects task cancellation

## License

[MIT](LICENSE)
