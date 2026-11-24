# App Sub-Map: 120Hz Native Collection Views & Artwork Pipeline

> Parent: [app/INDEX.md](INDEX.md). Covers 10 files under `Sources/DonbyApp/Components/`.

## 1. File Inventory & Responsibilities
- **AppKit 120Hz `NSCollectionView` / `CALayer` Stack**:
  - `Components/NativeCollectionHost.swift` — `FlippedLayerHostView`, `LayerOnlyCellRootView`, `NonDraggableScrollView`, `HorizontalShelfScrollView`, `HoverableCollectionItem`, `InteractiveCollectionView`, `ScrollHoverGate`, `NativeCardActionDelegate`.
  - `Components/NativeCardRenderCaches.swift` — `@MainActor NativeCardLayerCache` (sRGB normalization, offscreen `CGContext` gradient/symbol/pill caches, `configureBadgeLayer`), `CardTextBitmapCache` (`@unchecked Sendable` + `NSLock` + `OperationQueue` `com.don.CardTextRender` off-main-thread CoreText rasterizer).
  - `Components/NativePosterCollectionItem.swift` — pure `CALayer` dynamic-width poster cell shared by `NativePosterGridView` and `NativeEmbyHomeView`.
  - `Components/NativeShelfCollectionItems.swift` — pure `CALayer` fixed-size shelf cells (`NativeLandscapeCollectionItem` `248x180`, `NativeLibraryCollectionItem` `205x112`) and `private createTextLayer`.
  - `Components/NativeEmbyHomeView.swift` — 120Hz ProMotion vertical stack of horizontal shelves backed by `HorizontalShelfScrollView` + `InteractiveCollectionView`.
  - `Components/NativePosterGridView.swift` — 120Hz ProMotion adaptive poster wall backed by `InteractiveCollectionView`.
- **Artwork Cache & SwiftUI Media Views**:
  - `Components/ArtworkCacheEngine.swift` — `ScrollActivityTracker` (`NSLock`), `ArtworkImageCache` (3 `NSCache` tiers, `colorSpaceLock`, `diskQueue`, `decodeOperationQueue` max 4, 512 MiB disk cache / 410 MiB LRU prune target / 30d TTL, ImageIO hardware downsampling), `DownloadConcurrencyGate`, `ArtworkDownloadCoordinator`, `ArtworkDownloadManager`, `CGImageLoadCoordinator`.
  - `Components/MediaArtworkViews.swift` — `MediaArtworkView` (direct UHD fallback across `.primary`/`.backdrop`/`.thumb` + `Color.clear.overlay(alignment:) { Image.resizable().scaledToFill() }.clipped()`), `PersonAvatarView`, `RecordArtworkThumbnailView`, `ClearLogoHeaderView`.
  - `Components/HeroTopEdgeBackdrop.swift` — `HeroTopEdgeBackdropView` (`#03` weighted top-edge strip synthesized via `HeroTopEdgeSynthesizer`, matching hero Display P3/sRGB gamut with zero zoom/blur).
  - `Components/MediaCards.swift` — SwiftUI card equivalents (`PosterCardView`, `LandscapeCardView`) used in inline search and secondary surfaces.

## 2. Critical Invariants (DO NOT BREAK)
1. **120Hz Scroll Hygiene**: Never perform synchronous disk I/O, offscreen shadows, or SwiftUI layout thrashing inside `NativeEmbyHomeView` / `NativePosterGridView` scroll paths; respect `ScrollActivityTracker.isScrolling` and `ScrollHoverGate`. Keep `CATransaction.setDisableActions(true)` and `noImplicitActions` in all 3 `Native*CollectionItem` classes.
2. **Thread Isolation**: Keep `CardTextBitmapCache` non-isolated (`@unchecked Sendable` + `NSLock`, NEVER `@MainActor`) so CoreText rasterization stays off the main thread. Keep `ArtworkImageCache`'s internal lock/queue state (`colorSpaceLock`, `diskQueue`, `DecodeState`) encapsulated within a single type/file.
3. **Scroller & Hit-Testing**: Keep `HorizontalShelfScrollView` horizontal scroller hidden via `tile()`, avoid forced scroll-snapping, and preserve `InteractiveCollectionView` click/hover hit-testing (`v1.3.20` regression fix).
4. **Dual-Mode Artwork Fallback**: `MediaArtworkView.candidateURLs` must stay aligned with `EmbyClient+ArtworkAndFallback.swift` (zero `/emby/Items/...?api_key=` fallback when `isUHDNativeExtensionActive` is true).
