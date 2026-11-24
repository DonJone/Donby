# Kernel Sub-Module: Subtitles (`subtitle/`)

> Last synced: `v2.0.5`

## 1. Overview & Task-to-File Routing
- `KernelRust/src/subtitle/` (`3,696L` across 7 focused submodules): Single-track and dual-track subtitle decoding, normalization, semantic pairing, and RGBA rasterization.

| If your task involves... | Open |
| :--- | :--- |
| `SubtitleEngine` struct/fields, `new`, `close_stream_state`, `flush_for_seek`, `open_stream_decoder`, `Drop`, `mark_replayed` | `subtitle/mod.rs` (`485L`) |
| `decode_packet_for_slot`, `DecodeCtx` C callbacks, PGS bitmap cues, HDR/orange-gold pixel overrides | `subtitle/pgs.rs` (`408L`) |
| External SRT/VTT/ASS loading, `CFStringTransform`, ASS tag filtering, `feed_and_store_ass_event`, `rebuild_embedded_ass_track` | `subtitle/ass_text.rs` (`582L`) |
| `set_style`, `set_viewport`, `set_secondary_time_scale`, `get_vertical_bounds`, `get_intervals`, `apply_style_to_ass_track` | `subtitle/ass_style.rs` (`432L`) |
| `update_subtitle_rgba`, `clear_subtitle_canvas`, `raster_paired_line`, dual-layer RGBA blitting & dirty-rect tracking | `subtitle/compositor.rs` (`615L`) |
| Pair-A bilingual layout (`try_render_paired_bilingual`), 1200px viewport anchoring, cluster snap/tail-hold | `subtitle/pair_a_render.rs` (`619L`) |
| Pair-A ASS line extraction, speaker-dash splitting, `build_paired_turns`, Latin/CJK heuristics | `subtitle/pair_a_parse.rs` (`555L`) |

## 2. Core Capabilities
- **Dual Symmetric Slots**: Both primary and secondary subtitle slots independently support `libass` (`SRT`/`VTT`/`ASS`) with `CFStringTransform` (Simplified/Traditional conversion) AND PGS bitmap cues (`PgsCue`), supporting all 4 combinations (`Text+Text`, `PGS+Text`, `Text+PGS`, `PGS+PGS`).
- **Pair-A Cinema Semantic Bilingual Engine**:
  - Applies when `unify_pingfang_font` is enabled and no special ASS overrides (`\pos`, `\move`, `\org`, `\clip`, `\p1..9`, top alignments) are active.
  - Anchors to `1200px` reference viewport height (`PingFang SC` Bold / `PingFangSC-Medium`, primary `58px` `#FFFFFF`, secondary `35px` (`0.60x`) `#FFB22E`), without shrinking font size on 4-line cues.
  - Enforces `±450ms` cluster entry/overhang snap, `<=900ms` intra-cluster split gap bridging, and `<=1800ms` bidirectional safe tail-hold.
- **PGS Overrides**: Dark-outline-preserving HDR highlight normalization, pale-yellow enrichment to `#FFB22E`, automatic orange-gold tinting for secondary PGS tracks.
- **Non-Destructive Secondary Timing**: Evaluates `sec_pts = (pts - secondary_delay_sec) / secondary_time_scale` for `23.976 <-> 25fps` drift correction.
- **Local Test Matrix**: See git-ignored `docs/agent/local/SUBTITLE_TEST_MEDIA.md`.
