use crate::{text, Error, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::ops::Range;
use tokenizers::Tokenizer;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Surah {
    pub number: u16,
    pub name_en: String,
    pub name_ar: String,
    pub ayah_count: u16,
    pub bismillah: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SourceAyah {
    pub surah: u16,
    pub ayah: u16,
    pub arabic: String,
}
#[derive(Clone, Debug, Deserialize)]
pub struct Corpus {
    pub surahs: Vec<Surah>,
    pub ayahs: Vec<SourceAyah>,
    pub attribution: serde_json::Value,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Verse {
    pub surah: u16,
    pub ayah: u16,
    pub arabic: String,
    pub words: Vec<String>,
    pub tokens: Vec<u32>,
    pub word_token_ends: Vec<usize>,
    pub confusers: Vec<usize>,
}
impl Verse {
    pub fn tokens_for(&self, range: Range<usize>) -> (Vec<u32>, Vec<usize>) {
        let start = if range.start == 0 {
            0
        } else {
            self.word_token_ends[range.start - 1]
        };
        let end = self.word_token_ends[range.end - 1];
        (
            self.tokens[start..end].to_vec(),
            self.word_token_ends[range]
                .iter()
                .map(|x| x - start)
                .collect(),
        )
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CorpusIndex {
    pub version: u32,
    pub cache_key: String,
    pub surahs: Vec<Surah>,
    pub verses: Vec<Verse>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WordLocation {
    pub ayah: u16,
    pub word: usize,
}
impl Corpus {
    pub fn bundled() -> Result<Self> {
        Self::from_json(include_str!("../../../corpus/quran-uthmani.json"))
    }
    pub fn from_json(json: &str) -> Result<Self> {
        if json.len() > 8_000_000 {
            return Err(Error::Corpus("corpus exceeds size limit".into()));
        }
        let corpus: Self = serde_json::from_str(json).map_err(|e| Error::Corpus(e.to_string()))?;
        if corpus.surahs.len() != 114 || corpus.ayahs.len() != 6236 {
            return Err(Error::Corpus("expected 114 surahs and 6236 ayahs".into()));
        }
        let mut cursor = 0;
        for (s, i) in corpus.surahs.iter().zip(1..=114) {
            if s.number != i {
                return Err(Error::Corpus("surah order is invalid".into()));
            }
            for a in 1..=s.ayah_count {
                let v = corpus
                    .ayahs
                    .get(cursor)
                    .ok_or_else(|| Error::Corpus("ayah count mismatch".into()))?;
                if v.surah != s.number || v.ayah != a || v.arabic.trim().is_empty() {
                    return Err(Error::Corpus("ayah order/text is invalid".into()));
                }
                cursor += 1;
            }
        }
        if cursor != 6236 {
            return Err(Error::Corpus("ayah total mismatch".into()));
        }
        Ok(corpus)
    }
    pub fn cache_key(&self) -> String {
        let mut h = Sha256::new();
        h.update(include_bytes!("../../../model/tokenizer.json"));
        h.update(b"qrk-index-v1");
        for a in &self.ayahs {
            h.update(a.surah.to_le_bytes());
            h.update(a.ayah.to_le_bytes());
            h.update(a.arabic.as_bytes());
        }
        hex::encode(h.finalize())
    }
    pub fn build_index(&self) -> Result<CorpusIndex> {
        let tokenizer = Tokenizer::from_bytes(include_bytes!("../../../model/tokenizer.json"))
            .map_err(|e| Error::Corpus(e.to_string()))?;
        let mut verses: Vec<Verse> = self
            .ayahs
            .iter()
            .map(|a| {
                let arabic = self.numbered_text(a);
                let words = text::semantic_words(&arabic)
                    .iter()
                    .map(|w| text::normalize_arabic(w))
                    .collect();
                Verse {
                    surah: a.surah,
                    ayah: a.ayah,
                    arabic,
                    words,
                    tokens: Vec::new(),
                    word_token_ends: Vec::new(),
                    confusers: Vec::new(),
                }
            })
            .collect();
        let flat: Vec<&str> = verses
            .iter()
            .flat_map(|v| v.words.iter().map(String::as_str))
            .collect();
        let encoded = tokenizer
            .encode_batch(flat, false)
            .map_err(|e| Error::Corpus(e.to_string()))?;
        let mut i = 0;
        for v in &mut verses {
            for _ in &v.words {
                let ids = encoded[i].get_ids();
                if ids.is_empty() || ids.contains(&0) {
                    return Err(Error::Corpus("tokenizer emitted unknown Quran word".into()));
                }
                v.tokens.extend(ids);
                v.word_token_ends.push(v.tokens.len());
                i += 1;
            }
        }
        let graph = build_confusers(&verses);
        for (v, c) in verses.iter_mut().zip(graph) {
            v.confusers = c;
        }
        Ok(CorpusIndex {
            version: 1,
            cache_key: self.cache_key(),
            surahs: self.surahs.clone(),
            verses,
        })
    }
    /// Cache reuse must never change verbatim display text or canonical word boundaries.
    pub fn validates_index(&self, index: &CorpusIndex) -> bool {
        index.version == 1
            && index.cache_key == self.cache_key()
            && index.surahs == self.surahs
            && index.verses.len() == self.ayahs.len()
            && index.verses.iter().zip(&self.ayahs).all(|(v, a)| {
                let arabic = self.numbered_text(a);
                let words: Vec<_> = text::semantic_words(&arabic)
                    .iter()
                    .map(|w| text::normalize_arabic(w))
                    .collect();
                v.surah == a.surah
                    && v.ayah == a.ayah
                    && v.arabic == arabic
                    && v.words == words
                    && v.word_token_ends.len() == words.len()
                    && !v.tokens.is_empty()
                    && v.tokens.iter().all(|t| (1..1024).contains(t))
                    && v.word_token_ends.first().is_some_and(|n| *n > 0)
                    && v.word_token_ends.last() == Some(&v.tokens.len())
                    && v.word_token_ends.windows(2).all(|p| p[0] < p[1])
                    && v.confusers.iter().all(|i| *i < index.verses.len())
            })
    }
    fn numbered_text(&self, a: &SourceAyah) -> String {
        if a.ayah != 1 || a.surah == 1 || a.surah == 9 {
            return a.arabic.clone();
        }
        let header = &self.surahs[a.surah as usize - 1].bismillah;
        let prefix: Vec<_> = header.split_whitespace().collect();
        let words: Vec<_> = a.arabic.split_whitespace().collect();
        if prefix.len() == 4
            && words.len() > 4
            && prefix
                .iter()
                .zip(&words)
                .all(|(x, y)| text::letters(x) == text::letters(y))
        {
            // Slice, never normalize or rewrite, the display text.
            let mut starts = a.arabic.char_indices().filter(|(i, c)| {
                !c.is_whitespace()
                    && (*i == 0
                        || a.arabic[..*i]
                            .chars()
                            .next_back()
                            .is_some_and(char::is_whitespace))
            });
            if let Some((start, _)) = starts.nth(4) {
                return a.arabic[start..].to_owned();
            }
        }
        a.arabic.clone()
    }
}
impl CorpusIndex {
    pub fn verse(&self, surah: u16, ayah: u16) -> Option<&Verse> {
        self.verses
            .iter()
            .find(|v| v.surah == surah && v.ayah == ayah)
    }
    pub fn verse_index(&self, surah: u16, ayah: u16) -> Option<usize> {
        self.verses
            .iter()
            .position(|v| v.surah == surah && v.ayah == ayah)
    }
    pub fn canonical_words(&self, surah: u16) -> Vec<WordLocation> {
        self.verses
            .iter()
            .filter(|v| v.surah == surah)
            .flat_map(|v| (0..v.words.len()).map(|word| WordLocation { ayah: v.ayah, word }))
            .collect()
    }
    pub fn window(
        &self,
        surah: u16,
        cursor: usize,
        backtrack: usize,
        lookahead: usize,
    ) -> Result<Vec<WordLocation>> {
        let words = self.canonical_words(surah);
        if cursor > words.len() || lookahead == 0 || backtrack > 32 || lookahead > 128 {
            return Err(Error::Invalid("invalid canonical window".into()));
        }
        Ok(words[cursor.saturating_sub(backtrack)..(cursor + lookahead).min(words.len())].to_vec())
    }
}
fn build_confusers(verses: &[Verse]) -> Vec<Vec<usize>> {
    let mut postings: HashMap<&str, Vec<usize>> = HashMap::new();
    for (i, v) in verses.iter().enumerate() {
        for w in &v.words {
            let p = postings.entry(w).or_default();
            if p.last() != Some(&i) {
                p.push(i);
            }
        }
    }
    verses
        .iter()
        .enumerate()
        .map(|(i, v)| {
            let mut candidates: BTreeMap<usize, i32> = BTreeMap::new();
            for (wi, w) in v.words.iter().enumerate() {
                if let Some(list) = postings.get(w.as_str()) {
                    let weight = if wi == 0 || wi + 1 == v.words.len() {
                        4
                    } else {
                        1
                    };
                    let stride = (list.len() / 24).max(1);
                    for j in list.iter().step_by(stride).take(24) {
                        if i.abs_diff(*j) > 2 {
                            *candidates.entry(*j).or_default() += weight;
                        }
                    }
                }
            }
            for delta in [3, 4, 7, 13, 29, 113, 503] {
                candidates.entry((i + delta) % verses.len()).or_default();
            }
            let mut ranked: Vec<_> = candidates.into_iter().filter(|(j, _)| *j != i).collect();
            ranked.sort_by_key(|(j, n)| (-*n, verses[*j].words.len().abs_diff(v.words.len()), *j));
            ranked.into_iter().take(16).map(|x| x.0).collect()
        })
        .collect()
}
#[cfg(test)]
pub fn test_index() -> std::sync::Arc<CorpusIndex> {
    static INDEX: std::sync::OnceLock<std::sync::Arc<CorpusIndex>> = std::sync::OnceLock::new();
    INDEX
        .get_or_init(|| std::sync::Arc::new(Corpus::bundled().unwrap().build_index().unwrap()))
        .clone()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn counts_preamble_and_windows() {
        let i = test_index();
        assert_eq!(i.verses.len(), 6236);
        assert_eq!(i.surahs.len(), 114);
        assert_eq!(i.verse(95, 1).unwrap().words.len(), 2);
        assert_eq!(i.verse(97, 1).unwrap().words.len(), 5);
        assert_eq!(i.window(112, 4, 2, 3).unwrap().len(), 5);
        assert!(i.window(112, 0, 0, 0).is_err());
    }
    #[test]
    fn cached_display_cannot_change_tanzil_text() {
        let source = Corpus::bundled().unwrap();
        let mut index = (*test_index()).clone();
        assert!(source.validates_index(&index));
        index.verses[0].arabic.push('x');
        assert!(!source.validates_index(&index));
    }
    #[test]
    fn runtime_token_parity() {
        let Ok(path) = std::env::var("QRK_PARITY_TOKEN_MAP") else {
            eprintln!("SKIP: QRK_PARITY_TOKEN_MAP not set");
            return;
        };
        let map: serde_json::Value =
            serde_json::from_reader(std::fs::File::open(path).unwrap()).unwrap();
        let index = test_index();
        for (row, v) in map["ayahs"].as_array().unwrap().iter().zip(&index.verses) {
            assert_eq!(
                row[2],
                serde_json::json!(v.words),
                "{}:{} words",
                v.surah,
                v.ayah
            );
            assert_eq!(
                row[3],
                serde_json::json!(v.tokens),
                "{}:{} tokens",
                v.surah,
                v.ayah
            );
            assert_eq!(
                row[4],
                serde_json::json!(v.word_token_ends),
                "{}:{} boundaries",
                v.surah,
                v.ayah
            );
        }
    }
    #[test]
    fn scoped_variants() {
        let c = test_index();
        for (s, a, w) in [(1, 6, 1), (1, 7, 0), (112, 1, 3), (112, 4, 4)] {
            let v = c.verse(s, a).unwrap();
            let alt =
                text::alternate(s, a, 0, v.words.len(), &v.tokens, &v.word_token_ends).unwrap();
            assert_ne!(alt.0, v.tokens);
            assert_eq!(alt.1.len(), v.words.len());
            let excluded = if w == 0 { 1..v.words.len() } else { 0..w };
            let (t, e) = v.tokens_for(excluded.clone());
            assert!(text::alternate(s, a, excluded.start, excluded.end, &t, &e).is_none());
        }
    }
}
