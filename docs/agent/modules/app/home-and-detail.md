# App Sub-Map: Home, Carousel, Library Grid & DetailView

> Parent: [app/INDEX.md](INDEX.md). Covers 7 files: `EmbyMainView.swift`, `MainCarouselView.swift`, `Views/MLibListView.swift`, and `DetailView.swift` + 3 extensions.

## 1. File Inventory & Responsibilities
- `Sources/DonbyApp/EmbyMainView.swift` (`596L`) — Home root router (`selectedLibrary` -> `MLibListView`, unconfigured hero, error banner, inline debounced search, `NativeEmbyHomeView`), `homeShelves` builder (merges deduplicated `resumeItems` + `nextUpItems` into `继续观看`), `embyTopToolbar`, and shared `SectionHeaderView`.
- `Sources/DonbyApp/Views/MLibListView.swift` (`281L`) — Library category grid page with sort/filter/genre popover, `DonbySearchPillField`, `NativePosterGridView`, and dual-path (`DonbyAppExtensionCenter` cursor vs `EmbyClient` offset) pagination.
- `Sources/DonbyApp/MainCarouselView.swift` (`398L`) — Hero featured carousel (`365...540` responsive height) with `TrackpadHorizontalSwipeDetector`.
- `Sources/DonbyApp/DetailView.swift` (`461L`) — Detail root container, `@State` properties, `body` `ZStack(alignment: .top)` with static `HeroTopEdgeBackdropView` + pinned `floatingTopNavBar` + `DetailScrollViewTopInsetFix`.
- `Sources/DonbyApp/DetailView+HeroAndActions.swift` (`622L`) — `heroHeaderSection`, `ClearLogoHeaderView`, play/resume/download/favorite/version/audio/subtitle action controls, `effectivePlayButtonStartSeconds`.
- `Sources/DonbyApp/DetailView+SeasonsAndEpisodes.swift` (`456L`) — Season selector strip, episode cards (`MediaArtworkView` with `kind: .thumb`), cast/credits strip, similar/recommended shelves.
- `Sources/DonbyApp/DetailView+DataLoading.swift` (`533L`) — `loadFullDetailData`, `preferredFocusEpisodeId` (checks `item.isEpisode || initialItem.isEpisode`), `fetchMergedEpisodesForSeason` (applies `.withInheritedArtworkFallback(...)`), `runDetailPrewarmAndPreload`, async offline/Turbo status snapshots.

## 2. Critical Invariants (DO NOT BREAK)
1. **DetailView `#03` Static Top-Edge Strip, Zero Zoom/Blur & Scrollbar Hygiene (`v1.4.24–v1.4.31`)**:
   - Scale banner heights responsively (`DetailView`: `440...680`, `MainCarouselView`: `365...540`) and top-align wide artwork via `MediaArtworkView(alignment: .top)` so faces are never cropped.
   - Never mutate `DetailView` hero height/scale or apply blur during scroll or pull-down overscroll. Place static `HeroTopEdgeBackdropView` behind `.scrollContentBackground(.hidden)`.
   - Hide DetailView vertical/horizontal scrollbars via `ScrollView(showsIndicators: false)` + `DetailScrollViewTopInsetFix` (disabling `automaticallyAdjustsContentInsets` and zeroing `contentInsets.top`, `hasVerticalScroller`, `hasHorizontalScroller`).
   - Keep `floatingTopNavBar` pinned outside `ScrollView` in `DetailView.body`'s `ZStack(alignment: .top)`.
   - Dissolve hero smoothly in a single direction into `canvasCol` (`0.46 -> 1.0`); in `ClearLogoHeaderView`, never add white-halo glow on dark fallback text and suppress duplicate subtitle text underneath a loaded movie/series ClearLogo.
2. **Trackpad Swipe Detector Detach**: Detach `MainCarouselView`'s `TrackpadHorizontalSwipeDetector` whenever `appState.currentDetailItem != nil || appState.activePlayback != nil`, and never swallow `.began`/`.ended`/`.cancelled`/`.mayBegin` scroll-wheel lifecycle events (swallowing `.ended` freezes `DetailView` elastic bounce).
3. **Toolbar Clamping**: Never apply `.fixedSize(horizontal: true, vertical: false)` to variable-length API pills inside `embyTopToolbar`.
4. **Detail Preload Play-Button Binding (`v1.4.4`)**: `DetailView.effectivePlayButtonStartSeconds` binds background preloading directly to the Play button's exact start position (resume or auto-intro-skip landing) and re-evaluates on target/source/start updates.
5. **Card Interaction & Badge Consistency**: Clicking any poster or landscape card always enters `DetailView` (no hover center play button). Omit resolution badges and rating stars; downloaded badges use unified monochrome smoked-glass pill + white `checkmark` with `"已下载"` copy (never `"已离线下载"`).
