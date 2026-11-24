# Kernel Sub-Module: Subtitles (`subtitle.rs`)

> Last synced: `v2.0.4`

## 1. Overview
- `KernelRust/src/subtitle.rs` (~3,663L): Single-track and dual-track subtitle decoding, normalization, semantic pairing, and RGBA rasterization.
- Phase 2 of the `KernelRust` modularization plan will split `subtitle.rs` into `subtitle/*` submodules.

## 2. Core Capabilities
- **Dual Symmetric Slots**: Both primary and secondary subtitle slots independently support `libass` (`SRT`/`VTT`/`ASS`) with `CFStringTransform` (Simplified/Traditional conversion) AND PGS bitmap cues (`PgsCue`), supporting all 4 combinations (`Text+Text`, `PGS+Text`, `Text+PGS`, `PGS+PGS`).
- **Pair-A Cinema Semantic Bilingual Engine**:
  - Applies when `unify_pingfang_font` is enabled and no special ASS overrides (`\pos`, `\move`, `\org`, `\clip`, `\p1..9`, top alignments) are active.
  - Anchors to `1200px` reference viewport height (`PingFang SC` Bold / `PingFangSC-Medium`, primary `58px` `#FFFFFF`, secondary `35px` (`0.60x`) `#FFB22E`), without shrinking font size on 4-line cues.
  - Enforces `±450ms` cluster entry/overhang snap, `<=900ms` intra-cluster split gap bridging, and `<=1800ms` bidirectional safe tail-hold.
- **PGS Overrides**: Dark-outline-preserving HDR highlight normalization, pale-yellow enrichment to `#FFB22E`, automatic orange-gold tinting for secondary PGS tracks.
- **Non-Destructive Secondary Timing**: Evaluates `sec_pts = (pts - secondary_delay_sec) / secondary_time_scale` for `23.976 <-> 25fps` drift correction.
- **Local Test Matrix**: See git-ignored `docs/agent/local/SUBTITLE_TEST_MEDIA.md`.
