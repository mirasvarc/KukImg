<img src="docs/icon.png" width="128" align="left" alt="Kuk icon">

# Kuk

A fast, native macOS image viewer built with SwiftUI. Designed for flipping through large folders of photos with zero friction — thumbnails come from the system QuickLook cache, everything decodes off the main thread, and stale work is cancelled the moment you move on.

<!-- Add a screenshot: docs/screenshot.png -->

## Features

- **Fast grid browsing** — lazy grid with quantized thumbnail sizes, adjustable via a toolbar slider; thumbnails are served from a memory cache backed by QuickLook (the same cache Finder uses) with an ImageIO fallback
- **Instant navigation** — neighboring images are prefetched around the selection, and prefetches/decodes that fall out of view are cancelled, so holding an arrow key stays smooth even in huge folders
- **Detail view** — fit-to-window by default, pinch to zoom, double-click to toggle fit ↔ 100 %, zoom shortcuts (⌘+/⌘−/⌘1/⌘0), progressive loading (instant preview → display-size decode → full native decode only when zoom needs it), animated GIF playback, EXIF orientation handled correctly
- **Apple Photos library** — browse All Photos, Favorites, Recents and your albums straight from the sidebar (read-only); originals are exported to a size-capped cache on demand, so viewing stays instant and sharing/converting works on real files
- **Fullscreen mode** — distraction-free viewing with a slideshow (adjustable interval, optional loop, neighbors preloaded, cursor auto-hidden)
- **Culling** — flag images as Pick (P) or Reject (X), clear with U; filter the grid by flag, copy or move all picked images to a folder, send all rejected to Trash
- **Multi-selection** — ⇧/⌘-click, ⌘A, or an iPhone-style Selection Mode (⇧⌘S) with checkboxes; share, convert, copy, trash and rename act on the whole selection
- **Convert** (⇧⌘E) — batch conversion to PNG, JPEG, HEIC, TIFF, WebP, GIF or BMP with adjustable quality
- **Rename** (⌘⌥R) — single rename or batch rename with a numbered pattern (`Trip-###` → Trip-001, Trip-002, …)
- **Rotate** (⌘L/⌘R) — lossless rotation via the EXIF orientation tag
- **Metadata panel** — dimensions, camera, lens, ISO, shutter, aperture, focal length, GPS from EXIF with an Open in Maps link
- **Filter & sort** — live filename filter, eight sort orders (including Date Taken from EXIF), optional recursive folder scan with per-folder grouped sections, optional filename labels under thumbnails
- **Live folder watching** — files added or removed in Finder show up automatically
- **Finder integration** — drag & drop a folder (or a single image) in, drag images out, reveal in Finder, copy (file + bitmap), Open With menu, move to Trash with Undo
- **Open With** — registers as a viewer for images and folders, so it appears in Finder's Open With menu and can be set as the default image viewer (Get Info → Open with → Change All…)
- **Folder tree** — sidebar shows each open folder as a lazily loaded tree of its subfolders with per-folder image counts; multiple folders can be open at once (Add Folder… button, multi-select in the open panel) and closed individually
- **Settings** (⌘,) — startup, thumbnail and slideshow options, plus app info and update check
- **Recent folders** — sidebar and File → Open Recent, restored across launches via security-scoped bookmarks (the app is sandboxed); individual entries removable from the sidebar
- **Localized** — English and Czech
- **Automatic updates** — new versions are offered and installed in-app via [Sparkle](https://sparkle-project.org)

## Keyboard shortcuts

| Key | Action |
|---|---|
| ← → ↑ ↓ | Move selection (grid: by row/column) |
| Home / End | First / last image |
| Page Up / Page Down | Move by one screen of rows |
| Return / Space | Open fullscreen |
| Esc | Leave fullscreen / collapse selection |
| Space / P (fullscreen) | Toggle slideshow |
| P / X / U | Pick / Reject / Clear flag |
| ⌫, ⌘⌫ | Move to Trash |
| ⌘Z | Undo Move to Trash |
| ⌘+ / ⌘− | Zoom in / out |
| ⌘1 / ⌘0 | Actual size / Zoom to fit |
| ⌘O | Open folder |
| ⌘A | Select all |
| ⇧⌘S | Selection Mode |
| ⌘⌥S | Share |
| ⇧⌘E | Convert… |
| ⌘L / ⌘R | Rotate left / right |
| ⌘⌥R | Rename… |
| ⇧⌘C | Copy image |
| ⇧⌘R | Show in Finder |

## Installation

Download the latest `Kuk-v*.zip` from [Releases](https://github.com/mirasvarc/KukImg/releases), unzip, and move `Kuk.app` to `/Applications`.

> **Note:** the app is not notarized. On first launch macOS will refuse to open it — go to System Settings → Privacy & Security and click **Open Anyway**. This is needed only once; automatic updates install without it.

Or with Homebrew:

```bash
brew tap mirasvarc/tap
brew install --cask kuk
```

(The cask removes the quarantine flag automatically, so the app starts without Gatekeeper prompts.)

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 or later to build

## Building

```bash
git clone https://github.com/mirasvarc/KukImg.git
cd KukImg
open KukImg.xcodeproj
```

Build and run the `KukImg` scheme (⌘R). The only dependency is [Sparkle](https://sparkle-project.org) (automatic updates), resolved automatically via Swift Package Manager; everything else uses system frameworks (SwiftUI, AppKit, QuickLookThumbnailing, ImageIO, PhotoKit).

## Architecture notes

- `AppModel` — single `@Observable` model: folder scanning, selection & multi-selection, filtering, sorting, grouping, culling flags, folder watching, prefetch orchestration, trash with undo
- `PhotosLibraryModel` / `PhotosMaterializer` — Photos albums as lightweight items; originals are exported to an LRU-trimmed cache only when something needs a real file
- `ImageLoading` — one façade over both origins (files and Photos assets) for thumbnails, previews, full decodes and metadata
- `ThumbnailCache` — actor with separate NSCaches for grid thumbnails and large previews; requests are quantized into size buckets and fully cancellable
- `FullImageCache` — small LRU of fully decoded images so stepping back is instant
- `MetadataCache` — deduplicated EXIF reads shared by the status bar and info panel
- `PhotoCanvas` — shared image surface of the detail and fullscreen views: progressive loading, zoom & pan (NSScrollView-backed), neighbor prefetching
- All decoding runs off the main thread and respects task cancellation

## License

[MIT](LICENSE)
