# App Sub-Map: Home, Carousel, Library Grid & DetailView

> Parent: [app/INDEX.md](INDEX.md). Covers 7 files: `EmbyMainView.swift`, `MainCarouselView.swift`, `Views/MLibListView.swift`, and `DetailView.swift` + 3 extensions.

## 1. File Inventory & Responsibilities
- `Sources/DonbyApp/EmbyMainView.swift` — Home root router (`selectedLibrary` -> `MLibListView`, unconfigured hero, error banner, inline debounced search, `NativeEmbyHomeView`), `homeShelves` builder (merges deduplicated `resumeItems` + `nextUpItems` into `继续观看` and excludes anime shelves/items on non-anime servers and UHD Normal Hall via `HomeHeroCurator.isAnimeFocusedServer`), `embyTopToolbar`, and shared `SectionHeaderView`.
- `Sources/DonbyApp/Views/MLibListView.swift` — Library category grid page with sort/filter/genre popover, `DonbySearchPillField`, `NativePosterGridView`, and dual-path (`DonbyAppExtensionCenter` cursor vs `EmbyClient` offset) pagination.
- `Sources/DonbyApp/MainCarouselView.swift` — Hero featured carousel (`365...540` responsive height, `swipePublisher`, `HeroRatingBadgesRow` multi-platform rating badges with on-demand hydration) and `CarouselHostingView: NSHostingView<AnyView>` (direct responder-chain `scrollWheel(with:)` two-finger horizontal swipe with per-gesture axis locking).
- `Sources/DonbyApp/DetailView.swift` — Detail root container, `@State` properties (including `multiPlatformRatings` / `effectiveDetailRatings`), `body` `ZStack(alignment: .top)` with static `HeroTopEdgeBackdropView` + pinned `floatingTopNavBar` + `DetailScrollViewTopInsetFix`.
- `Sources/DonbyApp/DetailView+HeroAndActions.swift` — `heroHeaderSection` (with `HeroRatingBadgesRow` adapting to dark/light hero canvas), `ClearLogoHeaderView`, play/resume/download/favorite/version/audio/subtitle action controls, `effectivePlayButtonStartSeconds`.
- `Sources/DonbyApp/DetailView+SeasonsAndEpisodes.swift` — Season selector strip, episode cards (`MediaArtworkView` with `kind: .thumb` and `.onHover`/focus `180ms` candidate episode micro-staging), cast/credits strip, similar/recommended shelves.
- `Sources/DonbyApp/DetailView+DataLoading.swift` — `loadFullDetailData`, `preferredFocusEpisodeId` (checks `item.isEpisode || initialItem.isEpisode`), `fetchMergedEpisodesForSeason` (applies `.withInheritedArtworkFallback(...)`), `effectiveStartSeconds`, `stageHoveredOrFocusedEpisode`, `runDetailPrewarmAndPreload` (`50ms` control-plane fast-table populate + `220ms` full preload or `1.5 MiB` micro-stage), async offline/Turbo status snapshots.

## 2. Critical Invariants (DO NOT BREAK)
1. **DetailView `#03` Static Top-Edge Strip, Zero Zoom/Blur & Scrollbar Hygiene (`v1.4.24–v1.4.31`)**:
   - Scale banner heights responsively (`DetailView`: `440...680`, `MainCarouselView`: `365...540`) and top-align wide artwork via `MediaArtworkView(alignment: .top)` so faces are never cropped.
   - Never mutate `DetailView` hero height/scale or apply blur during scroll or pull-down overscroll. Place static `HeroTopEdgeBackdropView` behind `.scrollContentBackground(.hidden)`.
   - Hide DetailView vertical/horizontal scrollbars via `ScrollView(showsIndicators: false)` + `DetailScrollViewTopInsetFix` (disabling `automaticallyAdjustsContentInsets` and zeroing `contentInsets.top`, `hasVerticalScroller`, `hasHorizontalScroller`).
   - Keep `floatingTopNavBar` pinned outside `ScrollView` in `DetailView.body`'s `ZStack(alignment: .top)`.
   - Dissolve hero smoothly in a single direction into `canvasCol` (`0.46 -> 1.0`); in `ClearLogoHeaderView`, never add white-halo glow on dark fallback text and suppress duplicate subtitle text underneath a loaded movie/series ClearLogo.
2. **Carousel Trackpad Swipe via Responder Chain (`v2.0.14`)**: Handle hero carousel two-finger swipes directly in `CarouselHostingView.scrollWheel(with:)` (never via `NSEvent.addLocalMonitorForEvents`) so hidden home views never leak scroll interception into `DetailView`/`PlayerView`; forward vertical gesture boundaries (`.mayBegin`/`.began`/`.ended`/`.cancelled`) cleanly to `nextResponder` so outer elastic bounce never freezes.
3. **Toolbar Clamping**: Never apply `.fixedSize(horizontal: true, vertical: false)` to variable-length API pills inside `embyTopToolbar`.
4. **Detail Preload Play-Button Binding (`v1.4.4`)**: `DetailView.effectivePlayButtonStartSeconds` binds background preloading directly to the Play button's exact start position (resume or auto-intro-skip landing) and re-evaluates on target/source/start updates.
5. **Card Interaction & Badge Consistency**: Clicking any poster or landscape card always enters `DetailView` (no hover center play button). Omit resolution badges and rating stars; downloaded badges use unified monochrome smoked-glass pill + white `checkmark` with `"已下载"` copy (never `"已离线下载"`).
