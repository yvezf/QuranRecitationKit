use std::collections::BTreeSet;
use unicode_categories::UnicodeCategories;
pub fn normalize_arabic(text: &str) -> String {
    text.chars()
        .filter_map(|c| match c as u32 {
            0xfeff
            | 0x640
            | 0x670
            | 0x610..=0x61a
            | 0x64b..=0x65f
            | 0x6d6..=0x6de
            | 0x6df..=0x6ed => None,
            0x623 | 0x625 | 0x622 | 0x671 => Some('ا'),
            0x629 => Some('ه'),
            0x649 => Some('ي'),
            _ => Some(c),
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}
pub fn semantic_words(text: &str) -> Vec<String> {
    text.split_whitespace()
        .filter(|s| s.chars().any(|c| c.is_letter() || c.is_number()))
        .map(str::to_owned)
        .collect()
}
pub fn letters(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_letter() && *c != 'ـ')
        .collect()
}
pub fn levenshtein<T: Eq>(a: &[T], b: &[T]) -> usize {
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for (i, x) in a.iter().enumerate() {
        let mut current = vec![i + 1; b.len() + 1];
        for (j, y) in b.iter().enumerate() {
            current[j + 1] = (previous[j + 1] + 1)
                .min(current[j] + 1)
                .min(previous[j] + usize::from(x != y));
        }
        previous = current;
    }
    previous[b.len()]
}
pub fn words_match(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    let ac: Vec<_> = a.chars().collect();
    let bc: Vec<_> = b.chars().collect();
    ac.len() > 2
        && bc.len() > 2
        && (ac.len() + bc.len() - levenshtein(&ac, &bc)) as f64 / (ac.len() + bc.len()) as f64
            >= 0.70
}
pub fn align_words(decoded: &str, expected: &[String], from: usize, to: usize) -> BTreeSet<usize> {
    let mut pointer = from;
    let mut matched = BTreeSet::new();
    for w in semantic_words(&normalize_arabic(decoded)) {
        if pointer >= to {
            break;
        }
        if let Some(i) = (pointer..to.min(pointer + 5)).find(|i| words_match(&w, &expected[*i])) {
            matched.insert(i);
            pointer = i + 1;
        }
    }
    matched
}
/// Narrow alternate tokenizations measured in the original recognizer; never global spelling substitutions.
pub fn alternate(
    surah: u16,
    ayah: u16,
    from: usize,
    to: usize,
    tokens: &[u32],
    ends: &[usize],
) -> Option<(Vec<u32>, Vec<usize>)> {
    let word = if surah == 1 && (ayah == 6 || ayah == 7) {
        Some(if ayah == 6 { 1 } else { 0 })
    } else if surah == 112 && (ayah == 1 || ayah == 4) {
        Some(if ayah == 1 { 3 } else { 4 })
    } else {
        None
    }?;
    if !(from..to).contains(&word) {
        return None;
    }
    let local = word - from;
    if local >= ends.len() {
        return None;
    }
    let start = if local == 0 { 0 } else { ends[local - 1] };
    let end = ends[local];
    let original = &tokens[start..end];
    // Filled with the exact canonical/alternate arrays, kept under test against Swift.
    let replacement: Vec<u32> = if surah == 112 {
        if original != [49, 154] {
            return None;
        }
        vec![371]
    } else {
        if original != [117, 17, 40] && !(surah == 1 && ayah == 6 && original == [142, 17, 40]) {
            return None;
        }
        vec![original[0], 112, 40]
    };
    let mut result = tokens[..start].to_vec();
    result.extend(&replacement);
    result.extend_from_slice(&tokens[end..]);
    let delta = replacement.len() as isize - original.len() as isize;
    let adjusted = ends
        .iter()
        .enumerate()
        .map(|(i, n)| {
            if i >= local {
                (*n as isize + delta) as usize
            } else {
                *n
            }
        })
        .collect();
    Some((result, adjusted))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn normalization() {
        assert_eq!(
            normalize_arabic("\u{feff}أَلْـرَّحْمَٰنُ إِلَى رَحْمَةٍ"),
            "الرحمن الي رحمه"
        );
    }
    #[test]
    fn ordered_alignment() {
        assert_eq!(
            align_words(
                "alpha gamma",
                &["alpha".into(), "beta".into(), "gamma".into()],
                0,
                3
            ),
            BTreeSet::from([0, 2])
        );
    }
}
#[cfg(test)]
mod shared_fixture_tests {
    use super::*;
    #[derive(serde::Deserialize)]
    struct Fixture {
        expected: Vec<String>,
        decoded: String,
        from: usize,
        to: usize,
        matches: BTreeSet<usize>,
    }
    #[test]
    fn same_fixture_as_swift() {
        let fixtures: Vec<Fixture> =
            serde_json::from_str(include_str!("../../../tests/fixtures/aligner.json")).unwrap();
        for f in fixtures {
            assert_eq!(
                align_words(&f.decoded, &f.expected, f.from, f.to),
                f.matches
            );
        }
    }
}
