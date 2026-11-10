// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

use fff_query_parser::{Constraint, FFFQuery, FuzzyQuery, QueryParser};
use neo_frizbee::{CaseMatching, Config, Matcher, Scoring, SortStrategy};
use serde::{Deserialize, Serialize};
use std::panic::{AssertUnwindSafe, catch_unwind};

#[derive(Deserialize, Default)]
struct Request {
    query: String,
    paths: Vec<String>,
    #[serde(default, rename = "matchText")]
    match_text: bool,
}

#[derive(Serialize)]
struct Hit {
    index: usize,
    score: i32,
    // UTF-16 half-open ranges, matching Tatara's presentation contract.
    ranges: Vec<(usize, usize)>,
}

fn constraint_matches(c: &Constraint<'_>, path: &str) -> Result<bool, String> {
    let lower = path.to_lowercase();
    let name = lower.rsplit('/').next().unwrap_or(&lower);
    Ok(match c {
        Constraint::Extension(ext) => name.ends_with(&format!(".{}", ext.to_lowercase())),
        Constraint::Glob(pattern) => {
            let glob = globset::GlobBuilder::new(pattern)
                .case_insensitive(true)
                .literal_separator(true)
                .build()
                .map_err(|e| e.to_string())?
                .compile_matcher();
            glob.is_match(path) || (!pattern.contains('/') && glob.is_match(name))
        }
        Constraint::Text(text) => lower.contains(&text.to_lowercase()),
        Constraint::Parts(parts) => parts.iter().all(|p| lower.contains(&p.to_lowercase())),
        Constraint::Exclude(parts) => !parts.iter().any(|p| lower.contains(&p.to_lowercase())),
        Constraint::PathSegment(segment) => format!("/{lower}/")
            .contains(&format!("/{}/", segment.trim_matches('/').to_lowercase())),
        Constraint::FilePath(suffix) => {
            let suffix = suffix.to_lowercase();
            lower == suffix || lower.ends_with(&format!("/{suffix}"))
        }
        Constraint::Not(inner) => !constraint_matches(inner, path)?,
        Constraint::FileType(_) | Constraint::GitStatus(_) => {
            return Err("Files search supports paths, extensions, globs and exclusions; type/status qualifiers are unavailable.".into());
        }
    })
}

fn search(request: Request) -> Result<Vec<Hit>, String> {
    let parser = QueryParser::default();
    let query = if request.match_text {
        FFFQuery {
            raw_query: &request.query,
            fuzzy_query: FuzzyQuery::Text(&request.query),
            constraints: vec![],
            location: None,
        }
    } else {
        parser.parse(&request.query)
    };
    let parts: Vec<&str> = match &query.fuzzy_query {
        FuzzyQuery::Text(text) if !text.is_empty() => vec![text],
        FuzzyQuery::Parts(parts) => parts.clone(),
        _ => vec![],
    };
    let uppercase = parts
        .iter()
        .any(|part| part.chars().any(char::is_uppercase));
    let mut scores = vec![0i32; request.paths.len()];
    let mut indices = vec![Vec::<u32>::new(); request.paths.len()];
    let mut matches = vec![true; request.paths.len()];
    let filenames: Vec<&str> = request
        .paths
        .iter()
        .map(|path| path.rsplit('/').next().unwrap())
        .collect();
    for (index, path) in request.paths.iter().enumerate() {
        let extensions: Vec<_> = query
            .constraints
            .iter()
            .filter(|c| matches!(c, Constraint::Extension(_)))
            .collect();
        if !extensions.is_empty() {
            matches[index] = extensions
                .iter()
                .any(|c| constraint_matches(c, path).unwrap_or(false));
        }
        for constraint in &query.constraints {
            if !matches!(constraint, Constraint::Extension(_)) {
                matches[index] &= constraint_matches(constraint, path)?;
            }
        }
    }
    // The actual FFF parser and SIMD matcher are dependencies, not a Swift approximation.
    // Filename weighting follows fff-core/src/score.rs; PRs have no local frecency.
    for &part in &parts {
        let config = Config {
            casing: CaseMatching::Ignore,
            max_typos: Some(if part.chars().count() < 4 {
                0
            } else {
                (part.len() / 4).clamp(2, 6) as u16
            }),
            sort: SortStrategy::Unsorted,
            scoring: Scoring {
                capitalization_bonus: if uppercase { 8 } else { 0 },
                matching_case_bonus: if uppercase { 4 } else { 0 },
                ..Default::default()
            },
            ..Default::default()
        };
        let mut found = vec![false; request.paths.len()];
        let mut filename_matches = vec![None; request.paths.len()];
        if !request.match_text && !part.contains('/') {
            for hit in Matcher::new(part, &config).match_list_indices(&filenames) {
                let index = hit.index as usize;
                filename_matches[index] = Some(hit);
            }
        }
        let mut matcher = Matcher::new(part, &config);
        for hit in matcher.match_list_indices(&request.paths) {
            let index = hit.index as usize;
            found[index] = true;
            let base = hit.score as i32;
            scores[index] += base;
            indices[index].extend(hit.indices);
            if let Some(name_hit) = filename_matches[index].take() {
                let filename_offset = request.paths[index].len() - filenames[index].len();
                indices[index].extend(
                    name_hit
                        .indices
                        .iter()
                        .map(|&offset| offset + filename_offset as u32),
                );
                scores[index] += if name_hit.exact {
                    base / 5 * 2
                } else {
                    (base / 6).min(30)
                };
            }
        }
        for (index, value) in found.into_iter().enumerate() {
            matches[index] &= value;
        }
    }
    let mut result = Vec::new();
    for (index, path) in request.paths.iter().enumerate() {
        if !matches[index] {
            continue;
        }
        indices[index].sort_unstable();
        indices[index].dedup();
        let mut offset = 0;
        let mut ranges: Vec<(usize, usize)> = Vec::new();
        // Pinned neo_frizbee returns byte offsets, including for Unicode needles.
        // A matching byte highlights its complete scalar in Tatara's UTF-16 coordinates.
        for (byte_offset, ch) in path.char_indices() {
            let end = offset + ch.len_utf16();
            let matched = indices[index].partition_point(|&value| value < byte_offset as u32);
            if indices[index]
                .get(matched)
                .is_some_and(|&value| (value as usize) < byte_offset + ch.len_utf8())
            {
                if let Some(last) = ranges.last_mut().filter(|last| last.1 == offset) {
                    last.1 = end;
                } else {
                    ranges.push((offset, end));
                }
            }
            offset = end;
        }
        result.push(Hit {
            index,
            score: scores[index],
            ranges,
        });
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unicode_offsets_are_utf16() {
        for (query, expected) in [
            ("View", vec![(9, 13)]),
            ("Café", vec![(5, 9)]),
            ("폴더", vec![(2, 4)]),
        ] {
            let result = search(Request {
                query: query.into(),
                paths: vec!["😀폴더/CaféView.swift".into()],
                ..Default::default()
            })
            .unwrap();
            assert_eq!(result.len(), 1);
            assert_eq!(result[0].ranges, expected, "{query}");
        }
    }

    #[test]
    fn repeated_parent_and_filename_matches_keep_both_highlights_in_every_case() {
        let path = "NeedleDomain/Sources/NeedleController.swift";
        for query in ["needle", "Needle", "NEEDLE"] {
            let result = search(Request {
                query: query.into(),
                paths: vec![path.into()],
                ..Default::default()
            })
            .unwrap();
            assert_eq!(result.len(), 1);
            assert!(
                result[0].ranges.contains(&(0, 6)),
                "{query}: parent match missing"
            );
            let start = path.rfind("Needle").unwrap();
            assert!(
                result[0].ranges.contains(&(start, start + 6)),
                "{query}: filename match missing: {:?}",
                result[0].ranges
            );
        }
    }
}

/// The caller supplies valid buffers; returned bytes are freed by tatara_fff_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tatara_fff_search(
    input: *const u8,
    length: usize,
    output_length: *mut usize,
) -> *mut u8 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let data = unsafe { std::slice::from_raw_parts(input, length) };
        let request: Request = serde_json::from_slice(data).map_err(|e| e.to_string())?;
        search(request)
    }))
    .unwrap_or_else(|_| Err("FFF matcher failed.".into()));
    let output = match result {
        Ok(hits) => serde_json::json!({ "hits": hits }),
        Err(error) => serde_json::json!({ "error": error }),
    };
    let bytes = serde_json::to_vec(&output)
        .expect("JSON contains only serializable values")
        .into_boxed_slice();
    unsafe {
        *output_length = bytes.len();
    }
    Box::into_raw(bytes) as *mut u8
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tatara_fff_free(output: *mut u8, length: usize) {
    if !output.is_null() {
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                output, length,
            )));
        }
    }
}
