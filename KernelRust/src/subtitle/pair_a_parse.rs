use super::*;
use super::ass_text::{has_cjk_utf8, is_mostly_latin_line, style_looks_like_foreign_secondary};

fn trim_sub_ws(s: &str) -> &str {
    s.trim_matches([' ', '\t', '\r', '\n'])
}

pub(super) fn event_has_special_ass_effects(style_alignment: i32, text: &str) -> bool {
    if (style_alignment & 0x0C) != 0 {
        return true;
    }
    let b = text.as_bytes();
    let mut i = 0usize;
    while i < b.len() {
        if b[i] != b'{' {
            i += 1;
            continue;
        }
        let mut j = i + 1;
        while j < b.len() && b[j] != b'}' {
            if b[j] == b'\\' {
                let c1 = b.get(j + 1).map(|c| c.to_ascii_lowercase()).unwrap_or(0);
                let c2 = b.get(j + 2).map(|c| c.to_ascii_lowercase()).unwrap_or(0);
                let c3 = b.get(j + 3).map(|c| c.to_ascii_lowercase()).unwrap_or(0);
                if (c1 == b'p' && c2 == b'o' && c3 == b's')
                    || (c1 == b'm' && c2 == b'o' && c3 == b'v')
                    || (c1 == b'o' && c2 == b'r' && c3 == b'g')
                    || (c1 == b'c' && c2 == b'l' && c3 == b'i')
                    || (c1 == b'i' && c2 == b'c' && c3 == b'l')
                {
                    return true;
                }
                if c1 == b'p' && (b'1'..=b'9').contains(&c2) {
                    return true;
                }
                if c1 == b'a' && c2 == b'n' && (b'4'..=b'9').contains(&c3) {
                    return true;
                }
            }
            j += 1;
        }
        if j >= b.len() {
            break;
        }
        i = j + 1;
    }
    false
}

pub(super) fn extract_clean_lines_from_ass_text(
    raw_text: &str,
    style_is_foreign: bool,
    out_tagged: &mut Vec<(String, bool)>,
) {
    if raw_text.is_empty() {
        return;
    }
    let bytes = raw_text.as_bytes();
    let mut raw_parts = Vec::new();
    let mut start = 0usize;
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() && (bytes[i + 1] == b'N' || bytes[i + 1] == b'n') {
            raw_parts.push(&raw_text[start..i]);
            i += 2;
            start = i;
        } else if bytes[i] == b'\n' {
            raw_parts.push(&raw_text[start..i]);
            i += 1;
            start = i;
        } else {
            i += 1;
        }
    }
    raw_parts.push(&raw_text[start..]);

    let mut cur_italic = false;
    let mut cur_foreign_hint = style_is_foreign;
    for part in raw_parts {
        let mut clean = String::with_capacity(part.len());
        if cur_italic {
            clean.push_str("{\\i1}");
        }
        let mut part_has_visible = false;
        let pb = part.as_bytes();
        let mut k = 0usize;
        while k < pb.len() {
            if pb[k] == b'{' {
                if let Some(rel_close) = part[k + 1..].find('}') {
                    let close = k + 1 + rel_close;
                    let inner = &part[k + 1..close];
                    if inner.contains("\\i1") || inner.contains("\\I1") {
                        if !cur_italic {
                            clean.push_str("{\\i1}");
                            cur_italic = true;
                        }
                    } else if inner.contains("\\i0") || inner.contains("\\I0") {
                        if cur_italic {
                            clean.push_str("{\\i0}");
                            cur_italic = false;
                        }
                    }
                    if let Some(rpos) = inner.find("\\r") {
                        let rest = &inner[rpos + 2..];
                        let rname = rest.split('\\').next().unwrap_or("");
                        if !rname.is_empty() && style_looks_like_foreign_secondary(rname) {
                            cur_foreign_hint = true;
                        } else if rname.is_empty() {
                            cur_foreign_hint = style_is_foreign;
                        }
                    }
                    k = close + 1;
                    continue;
                }
            }
            if pb[k] == b'\\' && k + 1 < pb.len() && pb[k + 1] == b'h' {
                clean.push(' ');
                k += 2;
                continue;
            }
            let ch = part[k..].chars().next().unwrap();
            if ch != '\r' {
                clean.push(ch);
                if ch != ' ' && ch != '\t' {
                    part_has_visible = true;
                }
            }
            k += ch.len_utf8();
        }

        let trimmed = trim_sub_ws(&clean).to_owned();
        if !part_has_visible || trimmed.is_empty() {
            continue;
        }
        let is_foreign = if has_cjk_utf8(&trimmed) {
            false
        } else if is_mostly_latin_line(&trimmed) {
            true
        } else {
            cur_foreign_hint
        };
        out_tagged.push((trimmed, is_foreign));
    }
}

fn looks_like_speaker_dash(line: &str) -> bool {
    let mut s = line.trim_start_matches([' ', '\t']);
    if s.starts_with('{') {
        if let Some(close) = s.find('}') {
            s = s[close + 1..].trim_start_matches([' ', '\t']);
        }
    }
    s.starts_with('-') || s.starts_with('\u{2013}') || s.starts_with('\u{2014}')
}

fn try_split_inline_two_speakers(line: &str) -> Option<(String, String)> {
    let mut skip = 0usize;
    let mut count = 0usize;
    for ch in line.chars().take(2) {
        skip += ch.len_utf8();
        count += 1;
    }
    if count < 2 || skip >= line.len() {
        return None;
    }
    let tail = &line[skip..];
    let pos = tail
        .find(" - ")
        .or_else(|| tail.find("? -"))
        .or_else(|| tail.find("! -"))
        .or_else(|| tail.find(". -"))
        .map(|p| p + skip)?;
    let dash_pos = line[pos..].find('-').map(|p| pos + p)?;
    if dash_pos <= 1 || dash_pos + 1 >= line.len() {
        return None;
    }
    let a = trim_sub_ws(&line[..dash_pos]).to_owned();
    let b = trim_sub_ws(&line[dash_pos..]).to_owned();
    if !a.is_empty() && !b.is_empty() {
        Some((a, b))
    } else {
        None
    }
}

fn strip_ass_braces(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut i = 0usize;
    let b = line.as_bytes();
    while i < b.len() {
        if b[i] == b'{' {
            if let Some(rel_close) = line[i + 1..].find('}') {
                i = i + 1 + rel_close + 1;
                continue;
            }
        }
        let ch = line[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

fn is_bracket_or_music_line(line: &str) -> bool {
    let plain = strip_ass_braces(line);
    let t = trim_sub_ws(&plain);
    t.starts_with('[')
        || t.starts_with('(')
        || t.starts_with('\u{266A}')
        || t.starts_with('\u{266B}')
        || t.starts_with('\u{FF08}')
        || t.starts_with('\u{3010}')
}

fn utf8_visible_len(line: &str) -> usize {
    strip_ass_braces(line).chars().count()
}

fn join_two_lines(a: &str, b: &str, is_latin: bool) -> String {
    if a.is_empty() {
        return b.to_owned();
    }
    if b.is_empty() {
        return a.to_owned();
    }
    if is_latin {
        return format!("{a} {b}");
    }
    if a.ends_with(['，', '。', '！', '？', '、', '；', '：', '…', '—', ' ']) {
        format!("{a}{b}")
    } else {
        format!("{a} {b}")
    }
}

fn group_by_speaker_dash(lines: &[String], is_latin: bool) -> Vec<String> {
    if lines.len() <= 1 || !lines[1..].iter().any(|l| looks_like_speaker_dash(l)) {
        return lines.to_vec();
    }
    let mut grouped: Vec<String> = Vec::new();
    for l in lines {
        if grouped.is_empty() || looks_like_speaker_dash(l) || is_bracket_or_music_line(l) {
            grouped.push(l.clone());
        } else if let Some(last) = grouped.last_mut() {
            *last = join_two_lines(last, l, is_latin);
        }
    }
    grouped
}

fn reflow_non_dialogue_lines(lines: &[String], is_latin: bool) -> Vec<String> {
    if lines.len() <= 1 {
        return lines.to_vec();
    }
    for (i, l) in lines.iter().enumerate() {
        if (i > 0 && looks_like_speaker_dash(l)) || is_bracket_or_music_line(l) {
            return lines.to_vec();
        }
    }
    let mut merged = lines[0].clone();
    for l in &lines[1..] {
        merged = join_two_lines(&merged, l, is_latin);
    }
    vec![merged]
}

fn has_multi_speaker_dashes(lines: &[String]) -> bool {
    lines.len() >= 2 && lines[1..].iter().any(|l| looks_like_speaker_dash(l))
}

fn try_split_counterpart_by_anchor_ratio(line: &str, anchor_ratio: f64) -> Option<(String, String)> {
    if let Some(pair) = try_split_inline_two_speakers(line) {
        return Some(pair);
    }
    let total_vis = utf8_visible_len(line);
    if total_vis < 4 {
        return None;
    }
    let clamped_target = anchor_ratio.clamp(0.18, 0.82);

    struct Cand {
        split_after_byte: usize,
        next_start_byte: usize,
        ratio: f64,
        tier: i32,
    }
    let mut cands = Vec::new();
    let mut vis_so_far = 0usize;
    let mut in_brace = false;
    let mut i = 0usize;
    while i < line.len() {
        let ch = line[i..].chars().next().unwrap();
        let ch_len = ch.len_utf8();
        if ch == '{' {
            in_brace = true;
            i += ch_len;
            continue;
        }
        if in_brace {
            if ch == '}' {
                in_brace = false;
            }
            i += ch_len;
            continue;
        }
        vis_so_far += 1;
        let is_sent_end = matches!(ch, '?' | '!' | '？' | '！' | '。' | '…');
        let is_soft_sep = matches!(ch, ' ' | '\t' | '\u{3000}' | '，' | '；');

        if is_sent_end {
            let mut split_end = i + ch_len;
            while split_end < line.len() && matches!(line.as_bytes()[split_end], b'?' | b'!' | b'.') {
                split_end += 1;
                vis_so_far += 1;
            }
            let mut next_s = split_end;
            while next_s < line.len() && matches!(line.as_bytes()[next_s], b' ' | b'\t') {
                next_s += 1;
            }
            if next_s < line.len() {
                let r = (vis_so_far as f64) / (total_vis as f64);
                if (0.15..=0.85).contains(&r) {
                    cands.push(Cand { split_after_byte: split_end, next_start_byte: next_s, ratio: r, tier: 1 });
                }
            }
            i = split_end;
            continue;
        }
        if is_soft_sep {
            let keep_left = matches!(ch, '，' | '；');
            let split_end = if keep_left { i + ch_len } else { i };
            let mut next_s = i + ch_len;
            while next_s < line.len() && matches!(line.as_bytes()[next_s], b' ' | b'\t') {
                next_s += 1;
            }
            if split_end > 0 && next_s < line.len() {
                let r = (vis_so_far as f64) / (total_vis as f64);
                if (0.15..=0.85).contains(&r) {
                    cands.push(Cand { split_after_byte: split_end, next_start_byte: next_s, ratio: r, tier: 2 });
                }
            }
            i = next_s;
            continue;
        }
        i += ch_len;
    }

    let mut best: Option<&Cand> = None;
    let mut best_score = 1e9f64;
    for cand in &cands {
        let dist = (cand.ratio - clamped_target).abs();
        if cand.tier == 2 && dist > 0.28 {
            continue;
        }
        let score = dist + if cand.tier == 2 { 0.12 } else { 0.0 };
        if score < best_score {
            best_score = score;
            best = Some(cand);
        }
    }
    let b = best?;
    let out_a = trim_sub_ws(&line[..b.split_after_byte]).to_owned();
    let out_b = trim_sub_ws(&line[b.next_start_byte..]).to_owned();
    if !out_a.is_empty() && !out_b.is_empty() {
        Some((out_a, out_b))
    } else {
        None
    }
}

pub(super) fn track_looks_predominantly_latin(tr: *const c_void) -> bool {
    if tr.is_null() {
        return false;
    }
    let mut n_events = 0;
    unsafe { dk_shim_ass_track_meta(tr, ptr::null_mut(), &mut n_events, ptr::null_mut(), ptr::null_mut()) };
    if n_events <= 0 {
        return false;
    }
    let mut latin_hits = 0;
    let mut cjk_hits = 0;
    let step = (n_events / 24).max(1);
    let mut i = 0;
    while i < n_events && (latin_hits + cjk_hits) < 20 {
        let mut txt_p: *const c_char = ptr::null();
        if unsafe {
            dk_shim_ass_event_read(tr, i, ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), &mut txt_p)
        } && !txt_p.is_null()
        {
            let raw = unsafe { CStr::from_ptr(txt_p) }.to_string_lossy();
            let plain = strip_ass_braces(&raw);
            let clean = trim_sub_ws(&plain);
            if clean.len() >= 3 {
                if has_cjk_utf8(clean) {
                    cjk_hits += 1;
                } else if is_mostly_latin_line(clean) {
                    latin_hits += 1;
                }
            }
        }
        i += step;
    }
    latin_hits > cjk_hits
}

pub(super) fn build_paired_turns(
    pri_track_tagged: &[(String, bool)],
    sec_track_lines: &[String],
    anchor_is_secondary: bool,
) -> Vec<SemanticTurn> {
    let mut turns = Vec::new();

    let mut pair_or_reflow_two_lists = |cns_in: Vec<String>, ens_in: Vec<String>| {
        let mut cns = group_by_speaker_dash(&cns_in, false);
        let mut ens = group_by_speaker_dash(&ens_in, true);

        let split_ratio = |a: &str, b: &str| -> f64 {
            let la = utf8_visible_len(a).max(1) as f64;
            let lb = utf8_visible_len(b).max(1) as f64;
            la / (la + lb)
        };

        let en_has_2spk = ens.len() == 2
            && (looks_like_speaker_dash(&ens[0]) || looks_like_speaker_dash(&ens[1]))
            && looks_like_speaker_dash(&ens[1]);
        let cn_has_2spk = cns.len() == 2
            && (looks_like_speaker_dash(&cns[0]) || looks_like_speaker_dash(&cns[1]))
            && looks_like_speaker_dash(&cns[1]);

        if en_has_2spk && cns.len() == 1 {
            let ratio = split_ratio(&ens[0], &ens[1]);
            let split = if anchor_is_secondary {
                try_split_counterpart_by_anchor_ratio(&cns[0], ratio)
            } else {
                try_split_inline_two_speakers(&cns[0])
                    .or_else(|| try_split_counterpart_by_anchor_ratio(&cns[0], ratio))
            };
            if let Some((a, b)) = split {
                cns = vec![a, b];
            }
        } else if cn_has_2spk && ens.len() == 1 {
            let ratio = split_ratio(&cns[0], &cns[1]);
            let split = if !anchor_is_secondary {
                try_split_counterpart_by_anchor_ratio(&ens[0], ratio)
            } else {
                try_split_inline_two_speakers(&ens[0])
                    .or_else(|| try_split_counterpart_by_anchor_ratio(&ens[0], ratio))
            };
            if let Some((a, b)) = split {
                ens = vec![a, b];
            }
        }

        if cns.is_empty() {
            turns.push(SemanticTurn {
                pri_lines: Vec::new(),
                sec_lines: reflow_non_dialogue_lines(&ens, true),
            });
            return;
        }
        if ens.is_empty() {
            turns.push(SemanticTurn {
                pri_lines: reflow_non_dialogue_lines(&cns, false),
                sec_lines: Vec::new(),
            });
            return;
        }

        let is_two_speaker = has_multi_speaker_dashes(&cns) || has_multi_speaker_dashes(&ens);
        if cns.len() == ens.len() && cns.len() >= 2 {
            if is_two_speaker {
                for (c, e) in cns.into_iter().zip(ens.into_iter()) {
                    turns.push(SemanticTurn { pri_lines: vec![c], sec_lines: vec![e] });
                }
                return;
            }
            let total_cn: usize = cns.iter().map(|s| utf8_visible_len(s)).sum();
            let total_en: usize = ens.iter().map(|s| utf8_visible_len(s)).sum();
            let any_bracket =
                cns.iter().any(|s| is_bracket_or_music_line(s)) || ens.iter().any(|s| is_bracket_or_music_line(s));
            if !any_bracket && total_cn <= 26 && total_en <= 88 {
                turns.push(SemanticTurn {
                    pri_lines: reflow_non_dialogue_lines(&cns, false),
                    sec_lines: reflow_non_dialogue_lines(&ens, true),
                });
            } else {
                for (c, e) in cns.into_iter().zip(ens.into_iter()) {
                    turns.push(SemanticTurn { pri_lines: vec![c], sec_lines: vec![e] });
                }
            }
            return;
        }

        turns.push(SemanticTurn {
            pri_lines: reflow_non_dialogue_lines(&cns, false),
            sec_lines: reflow_non_dialogue_lines(&ens, true),
        });
    };

    if !sec_track_lines.is_empty() {
        let pri_lines: Vec<String> = pri_track_tagged.iter().map(|(l, _)| l.clone()).collect();
        pair_or_reflow_two_lists(pri_lines, sec_track_lines.to_vec());
        return turns;
    }

    if pri_track_tagged.is_empty() {
        return turns;
    }

    let any_pri = pri_track_tagged.iter().any(|(_, is_sec)| !*is_sec);
    let any_sec = pri_track_tagged.iter().any(|(_, is_sec)| *is_sec);
    if !any_pri || !any_sec {
        let mut mono: Vec<String> = pri_track_tagged.iter().map(|(l, _)| l.clone()).collect();
        let looks_latin = !mono.is_empty() && is_mostly_latin_line(&mono[0]);
        mono = group_by_speaker_dash(&mono, looks_latin);
        if !has_multi_speaker_dashes(&mono) {
            mono = reflow_non_dialogue_lines(&mono, looks_latin);
        }
        turns.push(SemanticTurn { pri_lines: mono, sec_lines: Vec::new() });
        return turns;
    }

    let mut is_interleaved = pri_track_tagged.len() >= 4 && pri_track_tagged.len() % 2 == 0;
    if is_interleaved {
        for pair in pri_track_tagged.chunks_exact(2) {
            if pair[0].1 == pair[1].1 {
                is_interleaved = false;
                break;
            }
        }
    }
    if is_interleaved {
        for pair in pri_track_tagged.chunks_exact(2) {
            let (pri, sec) = if !pair[0].1 {
                (pair[0].0.clone(), pair[1].0.clone())
            } else {
                (pair[1].0.clone(), pair[0].0.clone())
            };
            turns.push(SemanticTurn { pri_lines: vec![pri], sec_lines: vec![sec] });
        }
        return turns;
    }

    let mut cns = Vec::new();
    let mut ens = Vec::new();
    for (line, is_sec) in pri_track_tagged {
        if *is_sec {
            ens.push(line.clone());
        } else {
            cns.push(line.clone());
        }
    }
    pair_or_reflow_two_lists(cns, ens);
    turns
}
