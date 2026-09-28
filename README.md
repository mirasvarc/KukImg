<div align="center">

<img src="docs/icon.png" width="128" alt="Kuk icon">

# Kuk

**A fast, native macOS image viewer built with SwiftUI.**

Designed for flipping through large folders of photos with zero friction — thumbnails come from the system QuickLook cache, everything decodes off the main thread, and stale work is cancelled the moment you move on.

[![Latest release](https://img.shields.io/github/v/release/mirasvarc/KukImg?label=release)](https://github.com/mirasvarc/KukImg/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)](#requirements)
[![License](https://img.shields.io/github/license/mirasvarc/KukImg)](LICENSE)

[Features](#features) · [Shortcuts](#keyboard-shortcuts) · [Installation](#installation) · [Building](#building)

</div>

<!-- Add a screenshot: docs/screenshot.png -->

## Features

- **Fast grid browsing** — lazy grid with quantized thumbnail sizes, adjustable via a toolbar slider; thumbnails are served from a memory cache backed by QuickLook (the same cache Finder uses) with an ImageIO fallback
- **Instant navigation** — photos are decoded at the size of the viewer (not their native resolution), neighbors are prefetched in the direction you browse, a photo already in memory appears without any delay, and prefetches that fall out of view are cancelled, so holding an arrow key stays smooth even in folders with thousands of images
- **RAW friendly** — camera RAW files are shown from their embedded full-size preview while browsing; the raw data is only developed when you zoom in past it
- **Detail view** — fit-to-window by default, pinch to zoom, double-click to toggle fit ↔ 100 %, zoom shortcuts (⌘+/⌘−/⌘1/⌘0), progressive loading (instant preview → viewer-size decode → full native decode only when zoom needs it), animated GIF, APNG and WebP playback, EXIF orientation handled correctly
- **Apple Photos library** — browse All Photos, Favorites, Recents and your albums straight from the sidebar (read-only); photos are rendered by PhotoKit at screen size, edits made in Photos are shown, the album updates when the library changes, and originals are exported to a size-capped cache only for sharing, converting or deep zoom
- **Fullscreen mode** — distraction-free viewing with a slideshow (adjustable interval, optional loop, neighbors preloaded, cursor auto-hidden)
- **Culling** — flag images as Pick (P) or Reject (X), clear with U; filter the grid by flag, copy or move all picked images to a folder (in the background, with progress), send all rejected to Trash. Flags are saved as green "Pick" and red "Reject" Finder tags, so they survive quitting, travel with the files and are searchable in Finder and Spotlight (Photos items keep theirs inside Kuk)
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
- **Folder navigation** — jump to the next or previous folder that contains images (⌥⌘↓ / ⌥⌘↑) and to the enclosing folder (⌘↑) straight from the keyboard, also in fullscreen; the sidebar follows along
- **Settings** (⌘,) — startup, thumbnail and slideshow options, plus app info and update check
- **Recent folders** — sidebar and File → Open Recent, restored across launches via security-scoped bookmarks (the app is sandboxed); individual entries removable from the sidebar
- **Localized** — English and Czech
- **Automatic updates** — new versions are offered and installed in-app via [Sparkle](https://sparkle-project.org)

## Keyboard shortcuts

| Key | Action |
|---|---|
| ← → ↑ ↓ | Move selection (grid: by row/column) |
| Home / End | First / last image |
| Page Up / Page Down | Move by one screen of rows (fullscreen: previous / next image) |
| ⌥⌘↓ / ⌥⌘↑ | Next / previous folder with images |
| ⌘↑ | Enclosing folder |
| Return / Space | Open fullscreen |
| Esc | Leave fullscreen / collapse selection |
| Space (fullscreen) | Toggle slideshow |
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
- `ThumbnailCache` — one actor for thumbnails of files (QuickLook, ImageIO fallback) and Photos assets (PhotoKit); requests are quantized into size buckets, concurrent requests for the same thumbnail share one generation, and a generation is cancelled once nobody waits for it
- `FullImageCache` / `DecodeTier` — decodes sized to the viewport in 512 px steps (a bigger cached decode serves a smaller request), RAW embedded previews, shared in-flight decodes
- `FolderNavigator` — depth-first walk of the open folder trees for next/previous folder
- `FinderTags` / `AssetFlagStore` — culling flags persisted as coloured Finder tags, or in the app's defaults for Photos items
- `MetadataCache` — deduplicated EXIF reads shared by the status bar and info panel
- `PhotoCanvas` — shared image surface of the detail and fullscreen views: progressive loading, zoom & pan (NSScrollView-backed), neighbor prefetching
- All decoding runs off the main thread and respects task cancellation

## License

[MIT](LICENSE)
