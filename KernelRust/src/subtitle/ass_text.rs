use super::*;

impl SubtitleEngine {
    pub(super) fn feed_and_store_ass_event(
        &mut self,
        is_secondary: bool,
        raw_str: String,
        is_dialogue: bool,
        evt_forced: bool,
        start_ms: i64,
        dur_ms: i64,
    ) {
        let track = if is_secondary { self.secondary_ass_track } else { self.ass_track };
        if track.is_null() {
            return;
        }
        let events = if is_secondary {
            &mut self.secondary_ass_events
        } else {
            &mut self.primary_ass_events
        };
        if events.len() < 4096 {
            events.push(StoredAssEvent {
                start_ms,
                dur_ms,
                raw_line: raw_str.clone(),
                is_full_dialogue: is_dialogue,
                is_forced: evt_forced,
            });
        }
        if self.sub_style.forced_only && !evt_forced {
            return;
        }
        let transformed = transform_ass_line(
            &raw_str,
            self.sub_style.text_transform,
            is_dialogue,
            self.sub_style.unify_pingfang_font,
            self.sub_style.enhance_secondary_yellow,
        );
        unsafe {
            if is_dialogue {
                ass_process_data(track, transformed.as_ptr() as *const c_char, transformed.len() as c_int);
            } else {
                ass_process_chunk(
                    track,
                    transformed.as_ptr() as *const c_char,
                    transformed.len() as c_int,
                    start_ms as c_longlong,
                    dur_ms as c_longlong,
                );
            }
        }
    }

    pub fn load_external_subtitle(&mut self, content_utf8: &str, is_ass: bool, is_secondary: bool) {
        if self.ass_lib.is_null() {
            return;
        }
        unsafe {
            if is_secondary {
                dk_shim_close_codec(&mut self.secondary_sub_codec_ctx);
                self.secondary_ass_events.clear();
                self.secondary_codec_private.clear();
                self.secondary_pgs_cues.clear();
                self.secondary_has_bitmap_subs = false;
                self.secondary_time_scale = 1.0;
                self.rendered_secondary_pgs_gen = 0;
                self.secondary_ext_raw = content_utf8.to_owned();
                self.secondary_ext_is_ass = is_ass;
            } else {
                dk_shim_close_codec(&mut self.sub_codec_ctx);
                self.primary_ass_events.clear();
                self.primary_codec_private.clear();
                self.pgs_cues.clear();
                self.has_bitmap_subs = false;
                self.rendered_pgs_gen = 0;
                self.primary_ext_raw = content_utf8.to_owned();
                self.primary_ext_is_ass = is_ass;
            }
        }
        self.sub_rgba_buf.clear();
        self.sub_last_non_empty = false;
        self.sub_style_dirty = true;
        self.paired_layout_active = false;
        self.paired_layout_hash = 0;
        self.sub_dirty_y0 = 0;
        self.sub_dirty_y1 = 0;
        self.sub_serial += 1;
        let raw = if is_secondary {
            self.secondary_ext_raw.clone()
        } else {
            self.primary_ext_raw.clone()
        };
        self.populate_external_track(&raw, is_ass, is_secondary);
    }

    pub(super) fn populate_external_track(&mut self, raw_utf8: &str, is_ass: bool, is_secondary: bool) {
        let cur_track = if is_secondary { self.secondary_ass_track } else { self.ass_track };
        if !cur_track.is_null() {
            unsafe { ass_free_track(cur_track) };
            if is_secondary {
                self.secondary_ass_track = ptr::null_mut();
            } else {
                self.ass_track = ptr::null_mut();
            }
        }
        if raw_utf8.is_empty() || self.ass_lib.is_null() {
            return;
        }
        if is_ass {
            let transformed = transform_ass_document(
                raw_utf8,
                self.sub_style.text_transform,
                self.sub_style.unify_pingfang_font,
                self.sub_style.enhance_secondary_yellow,
            );
            let tr = unsafe {
                ass_read_memory(
                    self.ass_lib,
                    transformed.as_ptr() as *const c_char,
                    transformed.len(),
                    ptr::null(),
                )
            };
            if is_secondary {
                self.secondary_ass_track = tr;
            } else {
                self.ass_track = tr;
            }
            if !tr.is_null() {
                self.ensure_ass_track_header_for(tr, is_secondary);
            }
            return;
        }

        let tr = unsafe { ass_new_track(self.ass_lib) };
        if tr.is_null() {
            return;
        }
        if is_secondary {
            self.secondary_ass_track = tr;
        } else {
            self.ass_track = tr;
        }
        self.ensure_ass_track_header_for(tr, is_secondary);

        let text = raw_utf8.strip_prefix('\u{feff}').unwrap_or(raw_utf8);
        let mut cue_start: i64 = -1;
        let mut cue_end: i64 = -1;
        let mut cue_body = String::new();

        let flush_cue = |this: &mut Self, cs: &mut i64, ce: &mut i64, body: &mut String| {
            if *cs >= 0 && *ce > *cs && !body.is_empty() {
                let mut sanitized = sanitize_srt_vtt_tags(body);
                if !is_secondary && this.sub_style.enhance_secondary_yellow {
                    if let Some(br) = sanitized.find("\\N") {
                        if br > 0 && br + 2 < sanitized.len() {
                            let line1 = &sanitized[..br];
                            let line2 = &sanitized[br + 2..];
                            if has_cjk_utf8(line1)
                                && is_mostly_latin_line(line2)
                                && !line2.contains("\\c&")
                                && !line2.contains("\\1c&")
                            {
                                sanitized = format!("{line1}\\N{{\\fscx62\\fscy62\\1c&H002EB2FF&}}{line2}");
                            }
                        }
                    }
                }
                let transformed = transform_ass_payload(
                    &sanitized,
                    this.sub_style.text_transform,
                    this.sub_style.unify_pingfang_font,
                    this.sub_style.enhance_secondary_yellow,
                );
                this.sub_read_order += 1;
                let chunk = format!("{},0,Default,,0,0,0,,{}", this.sub_read_order, transformed);
                unsafe {
                    ass_process_chunk(
                        tr,
                        chunk.as_ptr() as *const c_char,
                        chunk.len() as c_int,
                        *cs as c_longlong,
                        (*ce - *cs) as c_longlong,
                    );
                }
            }
            *cs = -1;
            *ce = -1;
            body.clear();
        };

        for raw_line in text.split('\n') {
            let line = raw_line.strip_suffix('\r').unwrap_or(raw_line);
            if line.is_empty() {
                flush_cue(self, &mut cue_start, &mut cue_end, &mut cue_body);
                continue;
            }
            if cue_start < 0
                && (line.starts_with("WEBVTT") || line.starts_with("NOTE") || line.starts_with("STYLE"))
            {
                continue;
            }
            if let Some(arrow) = line.find("-->") {
                flush_cue(self, &mut cue_start, &mut cue_end, &mut cue_body);
                let lhs = line[..arrow].trim_start();
                let rhs_full = line[arrow + 3..].trim_start();
                let rhs = rhs_full.split([' ', '\t']).next().unwrap_or(rhs_full);
                cue_start = parse_srt_time_ms(lhs);
                cue_end = parse_srt_time_ms(rhs);
            } else if cue_start >= 0 {
                if !cue_body.is_empty() {
                    cue_body.push_str("\\N");
                }
                cue_body.push_str(line);
            }
        }
        flush_cue(self, &mut cue_start, &mut cue_end, &mut cue_body);
    }

    pub(super) fn rebuild_embedded_ass_track(&mut self, is_secondary: bool) {
        let old = if is_secondary { self.secondary_ass_track } else { self.ass_track };
        if !old.is_null() {
            unsafe { ass_free_track(old) };
            if is_secondary {
                self.secondary_ass_track = ptr::null_mut();
            } else {
                self.ass_track = ptr::null_mut();
            }
        }
        if self.ass_lib.is_null() {
            return;
        }
        let tr = unsafe { ass_new_track(self.ass_lib) };
        if tr.is_null() {
            return;
        }
        if is_secondary {
            self.secondary_ass_track = tr;
        } else {
            self.ass_track = tr;
        }
        let priv_bytes = if is_secondary {
            &self.secondary_codec_private
        } else {
            &self.primary_codec_private
        };
        if !priv_bytes.is_empty() {
            unsafe {
                ass_process_codec_private(tr, priv_bytes.as_ptr() as *const c_char, priv_bytes.len() as c_int);
            }
        }
        self.ensure_ass_track_header_for(tr, is_secondary);
        let events = if is_secondary {
            self.secondary_ass_events.clone()
        } else {
            self.primary_ass_events.clone()
        };
        for ev in &events {
            if self.sub_style.forced_only && !ev.is_forced {
                continue;
            }
            let transformed = transform_ass_line(
                &ev.raw_line,
                self.sub_style.text_transform,
                ev.is_full_dialogue,
                self.sub_style.unify_pingfang_font,
                self.sub_style.enhance_secondary_yellow,
            );
            unsafe {
                if ev.is_full_dialogue {
                    ass_process_data(tr, transformed.as_ptr() as *const c_char, transformed.len() as c_int);
                } else {
                    ass_process_chunk(
                        tr,
                        transformed.as_ptr() as *const c_char,
                        transformed.len() as c_int,
                        ev.start_ms as c_longlong,
                        ev.dur_ms as c_longlong,
                    );
                }
            }
        }
    }
}

fn cf_transform_segment(seg: &str, mode: i32) -> String {
    if mode == 0 || seg.is_empty() {
        return seg.to_owned();
    }
    let cap = seg.len() * 4 + 32;
    let mut dst = vec![0u8; cap];
    let written = unsafe { dk_shim_cf_transform_utf8(seg.as_ptr(), seg.len(), mode, dst.as_mut_ptr(), cap) };
    if written == 0 {
        return seg.to_owned();
    }
    String::from_utf8_lossy(&dst[..written]).into_owned()
}

pub(super) fn is_pale_yellow_rgb(r: u8, g: u8, b: u8) -> bool {
    if r < 175 || g < 145 {
        return false;
    }
    if (r as i32) - (b as i32) < 16 {
        return false;
    }
    if (g as i32) - (b as i32) < 12 {
        return false;
    }
    if ((r as i32) - (g as i32)).abs() > 85 {
        return false;
    }
    true
}

pub(super) fn style_looks_like_foreign_secondary(name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    let lower = name.to_ascii_lowercase();
    lower.contains("eng")
        || lower.contains("english")
        || lower.contains("sub")
        || lower.contains("sec")
        || lower.contains("foreign")
        || lower.contains("en_")
        || lower.contains("_en")
        || lower == "en"
        || lower.contains('英')
        || lower.contains('外')
        || lower.contains('日')
        || lower.contains('韩')
}

pub(super) fn has_cjk_utf8(s: &str) -> bool {
    let bytes = s.as_bytes();
    bytes.windows(3).any(|w| (0xE4..=0xE9).contains(&w[0]))
}

pub(super) fn is_mostly_latin_line(s: &str) -> bool {
    let mut latin = 0;
    let mut in_tag = false;
    for &b in s.as_bytes() {
        if b == b'{' {
            in_tag = true;
            continue;
        }
        if b == b'}' {
            in_tag = false;
            continue;
        }
        if in_tag {
            continue;
        }
        if (0xE4..=0xE9).contains(&b) {
            return false;
        }
        if b.is_ascii_alphabetic() {
            latin += 1;
        }
    }
    latin >= 2
}

fn filter_ass_tag_block(block: &str, strip_font: bool, enhance_yellow: bool) -> String {
    if (!strip_font && !enhance_yellow) || block.len() < 2 || !block.starts_with('{') || !block.ends_with('}') {
        return block.to_owned();
    }
    let inner = &block[1..block.len() - 1];
    let bytes = inner.as_bytes();
    let mut out = String::with_capacity(inner.len() + 8);
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] != b'\\' {
            out.push(bytes[i] as char);
            i += 1;
            continue;
        }
        let next_bs = inner[i + 1..].find('\\').map(|p| i + 1 + p).unwrap_or(inner.len());
        let tok = &inner[i..next_bs];
        i = next_bs;
        let tb = tok.as_bytes();

        if strip_font && tb.len() >= 3 && tb[1].eq_ignore_ascii_case(&b'f') && tb[2].eq_ignore_ascii_case(&b'n') {
            continue;
        }
        if enhance_yellow
            && ((tb.len() >= 3 && tb[1].eq_ignore_ascii_case(&b'c') && tb[2] == b'&')
                || (tb.len() >= 4 && tb[1] == b'1' && tb[2].eq_ignore_ascii_case(&b'c') && tb[3] == b'&'))
        {
            if let Some(h_pos) = tok.find(['H', 'h']) {
                let hex: String = tok[h_pos + 1..]
                    .chars()
                    .take_while(|c| c.is_ascii_hexdigit())
                    .collect();
                if (3..=8).contains(&hex.len()) {
                    if let Ok(val) = u32::from_str_radix(&hex, 16) {
                        let r = (val & 0xFF) as u8;
                        let g = ((val >> 8) & 0xFF) as u8;
                        let b = ((val >> 16) & 0xFF) as u8;
                        if is_pale_yellow_rgb(r, g, b) {
                            out.push_str("\\1c&H002EB2FF&");
                            continue;
                        }
                    }
                }
            }
        }
        out.push_str(tok);
    }
    if out.is_empty() {
        String::new()
    } else {
        format!("{{{out}}}")
    }
}

fn transform_ass_payload(payload: &str, mode: i32, strip_font: bool, enhance_yellow: bool) -> String {
    if (mode == 0 && !strip_font && !enhance_yellow) || payload.is_empty() {
        return payload.to_owned();
    }
    let bytes = payload.as_bytes();
    let mut out = String::with_capacity(payload.len() + 32);
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'{' {
            if let Some(rel_close) = payload[i + 1..].find('}') {
                let close = i + 1 + rel_close;
                out.push_str(&filter_ass_tag_block(&payload[i..=close], strip_font, enhance_yellow));
                i = close + 1;
                continue;
            }
        }
        if bytes[i] == b'\\' && i + 1 < bytes.len() && matches!(bytes[i + 1], b'N' | b'n' | b'h') {
            out.push_str(&payload[i..i + 2]);
            i += 2;
            continue;
        }
        let start = i;
        while i < bytes.len()
            && bytes[i] != b'{'
            && !(bytes[i] == b'\\' && i + 1 < bytes.len() && matches!(bytes[i + 1], b'N' | b'n' | b'h'))
        {
            i += 1;
        }
        if mode != 0 {
            out.push_str(&cf_transform_segment(&payload[start..i], mode));
        } else {
            out.push_str(&payload[start..i]);
        }
    }

    if enhance_yellow {
        if let Some(br) = out.find("\\N") {
            if br > 0 && br + 2 < out.len() {
                let line1 = &out[..br];
                let line2 = &out[br + 2..];
                let has_color = line2.contains("\\1c&")
                    || line2.contains("\\c&")
                    || line2.contains("\\1C&")
                    || line2.contains("\\C&");
                if !has_color && has_cjk_utf8(line1) && is_mostly_latin_line(line2) {
                    out = format!("{line1}\\N{{\\1c&H002EB2FF&}}{line2}");
                }
            }
        }
    }
    out
}

fn transform_ass_line(line: &str, mode: i32, is_full_dialogue: bool, strip_font: bool, enhance_yellow: bool) -> String {
    if (mode == 0 && !strip_font && !enhance_yellow) || line.is_empty() {
        return line.to_owned();
    }
    let target_commas = if is_full_dialogue { 9 } else { 8 };
    let mut seen = 0;
    let mut split_pos = None;
    for (idx, b) in line.bytes().enumerate() {
        if b == b',' {
            seen += 1;
            if seen == target_commas {
                split_pos = Some(idx + 1);
                break;
            }
        }
    }
    match split_pos {
        Some(sp) if sp < line.len() => {
            format!("{}{}", &line[..sp], transform_ass_payload(&line[sp..], mode, strip_font, enhance_yellow))
        }
        _ => transform_ass_payload(line, mode, strip_font, enhance_yellow),
    }
}

fn transform_ass_document(doc: &str, mode: i32, strip_font: bool, enhance_yellow: bool) -> String {
    if (mode == 0 && !strip_font && !enhance_yellow) || doc.is_empty() {
        return doc.to_owned();
    }
    let mut out = String::with_capacity(doc.len() + 32);
    for chunk in doc.split_inclusive('\n') {
        if chunk.starts_with("Dialogue:") {
            out.push_str(&transform_ass_line(chunk, mode, true, strip_font, enhance_yellow));
        } else {
            out.push_str(chunk);
        }
    }
    out
}

pub(super) fn parse_srt_time_ms(t: &str) -> i64 {
    let t = t.trim();
    let parts: Vec<&str> = t.split(':').collect();
    if parts.len() == 3 {
        let hh: i64 = parts[0].parse().unwrap_or(-1);
        let mm: i64 = parts[1].parse().unwrap_or(-1);
        let mut sec_parts = parts[2].split([',', '.']);
        let ss: i64 = sec_parts.next().and_then(|s| s.parse().ok()).unwrap_or(-1);
        let ms_str = sec_parts.next().unwrap_or("0");
        let ms: i64 = parse_frac_ms(ms_str);
        if hh >= 0 && mm >= 0 && ss >= 0 && ms >= 0 {
            return (hh * 3600 + mm * 60 + ss) * 1000 + ms;
        }
    } else if parts.len() == 2 {
        let mm: i64 = parts[0].parse().unwrap_or(-1);
        let mut sec_parts = parts[1].split([',', '.']);
        let ss: i64 = sec_parts.next().and_then(|s| s.parse().ok()).unwrap_or(-1);
        let ms_str = sec_parts.next().unwrap_or("0");
        let ms: i64 = parse_frac_ms(ms_str);
        if mm >= 0 && ss >= 0 && ms >= 0 {
            return (mm * 60 + ss) * 1000 + ms;
        }
    }
    -1
}

fn parse_frac_ms(s: &str) -> i64 {
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).take(3).collect();
    if digits.is_empty() {
        return -1;
    }
    let val: i64 = digits.parse().unwrap_or(0);
    match digits.len() {
        1 => val * 100,
        2 => val * 10,
        _ => val,
    }
}

pub(super) fn sanitize_srt_vtt_tags(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = String::with_capacity(raw.len() + 8);
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'<' {
            if let Some(rel_close) = raw[i + 1..].find('>') {
                let close = i + 1 + rel_close;
                let tag = raw[i + 1..close].to_ascii_lowercase();
                match tag.as_str() {
                    "i" => out.push_str("{\\i1}"),
                    "/i" => out.push_str("{\\i0}"),
                    "b" => out.push_str("{\\b1}"),
                    "/b" => out.push_str("{\\b0}"),
                    "u" => out.push_str("{\\u1}"),
                    "/u" => out.push_str("{\\u0}"),
                    _ => {}
                }
                i = close + 1;
                continue;
            }
        }
        let ch = raw[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

pub(super) fn ass_text_is_vector_drawing(text: &str) -> bool {
    let b = text.as_bytes();
    b.windows(3).any(|w| w[0] == b'\\' && w[1] == b'p' && (b'1'..=b'9').contains(&w[2]))
}
