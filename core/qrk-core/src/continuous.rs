//! Positional confirmation ported from TilawaContinuousSurahRecitationSession.
//! The cursor is an anchor, never a search across later expected words. Silence
//! confirms existing lexical/acoustic evidence; it cannot create that evidence.
use crate::{ctc::WordEmission, text};
use std::collections::BTreeMap;

pub const MIN_LEXICAL: f64 = 0.70;
pub const STRONG_LEXICAL: f64 = 0.88;
pub const NATURAL_PAUSE: usize = 4_800;

#[derive(Clone, Debug)]
pub struct WordMatch {
    pub decoded: usize,
    pub similarity: f64,
}
#[derive(Default)]
pub struct Alignment {
    pub words: Vec<WordMatch>,
    pub backtrack: usize,
}
pub fn similarity(a: &str, b: &str) -> f64 {
    let a: Vec<_> = a.chars().collect();
    let b: Vec<_> = b.chars().collect();
    let n = a.len() + b.len();
    if n == 0 {
        1.
    } else {
        (n - text::levenshtein(&a, &b)) as f64 / n as f64
    }
}
fn best(decoded: &[WordEmission], expected: &str, from: usize, to: usize) -> Option<WordMatch> {
    let mut result: Option<WordMatch> = None;
    for (i, word) in decoded.iter().enumerate().take(to).skip(from) {
        let score = similarity(&word.text, expected);
        if result.as_ref().is_none_or(|p| score > p.similarity) {
            result = Some(WordMatch {
                decoded: i,
                similarity: score,
            });
        }
    }
    result.filter(|p| p.similarity >= MIN_LEXICAL)
}
/// Same 2-insertion allowance, no expected deletion, backtrack tie break and
/// most-recent-equivalent anchor as the Swift reference's anchored aligner.
pub fn align(
    decoded: &[WordEmission],
    expected: &[String],
    anchor: usize,
    minimum_frame: usize,
) -> Alignment {
    let mut result = Alignment::default();
    let mut result_mean = 0.;
    for i in decoded.len().saturating_sub(32)..decoded.len() {
        if decoded[i].start < minimum_frame {
            continue;
        }
        let score = similarity(&decoded[i].text, &expected[anchor]);
        if score < MIN_LEXICAL {
            continue;
        }
        let mut words = vec![WordMatch {
            decoded: i,
            similarity: score,
        }];
        let mut prior = i;
        for word in &expected[anchor + 1..] {
            let Some(found) = best(decoded, word, prior + 1, (prior + 4).min(decoded.len())) else {
                break;
            };
            prior = found.decoded;
            words.push(found);
        }
        let mut backtrack = 0;
        let mut upper = i;
        for word in expected[..anchor].iter().rev() {
            if upper == 0 {
                break;
            }
            let Some(found) = best(decoded, word, upper.saturating_sub(3), upper) else {
                break;
            };
            upper = found.decoded;
            backtrack += 1;
        }
        let mean = words.iter().map(|m| m.similarity).sum::<f64>() / words.len() as f64;
        let prefer = words.len() > result.words.len()
            || (words.len() == result.words.len()
                && (backtrack > result.backtrack
                    || (backtrack == result.backtrack
                        && (mean > result_mean
                            || (mean == result_mean
                                && result.words.first().is_none_or(|m| i > m.decoded))))));
        if prefer {
            result = Alignment { words, backtrack };
            result_mean = mean;
        }
    }
    result
}

#[derive(Clone)]
struct Evidence {
    sample: u64,
    voice: u64,
}
#[derive(Default, Clone, Copy)]
pub struct Boundary {
    pub count: usize,
    pub strong: bool,
    pub following: bool,
    pub backtrack: usize,
    pub pause: usize,
    pub terminal: bool,
    pub surah_endpoint: bool,
}
#[derive(Default)]
pub struct EvidenceLedger {
    words: BTreeMap<usize, Vec<Evidence>>,
}
impl EvidenceLedger {
    pub fn observe(&mut self, matches: &[WordMatch], sample: u64, voice: u64) {
        for (word, _) in matches.iter().enumerate() {
            let history = self.words.entry(word).or_default();
            if history.last().is_none_or(|e| e.sample != sample) {
                history.push(Evidence { sample, voice });
                if history.len() > 4 {
                    history.remove(0);
                }
            }
        }
    }
    fn two_fresh(&self, word: usize) -> bool {
        let Some(history) = self.words.get(&word) else {
            return false;
        };
        history.iter().enumerate().any(|(i, a)| {
            history[i + 1..].iter().any(|b| {
                b.sample.saturating_sub(a.sample) >= 3_200
                    && b.voice.saturating_sub(a.voice) >= 3_200
            })
        })
    }
    pub fn confirmed(&self, matches: &[WordMatch], boundary: Boundary) -> bool {
        let Boundary {
            count,
            strong,
            following,
            backtrack,
            pause,
            terminal,
            surah_endpoint,
        } = boundary;
        if matches.len() < count {
            return false;
        }
        // Swift completeBreathAyahEndpoint: all remaining words directly >=.74,
        // adequate passage acoustics, at least one strong, natural pause.
        if pause >= NATURAL_PAUSE
            && count > 1
            && matches[..count].iter().all(|m| m.similarity >= 0.74)
            && strong
            && matches[..count]
                .iter()
                .any(|m| m.similarity >= STRONG_LEXICAL)
        {
            return true;
        }
        (0..count).all(|i| {
            let is_strong = strong && matches[i].similarity >= STRONG_LEXICAL;
            let context = i > 0 || backtrack > 0;
            self.two_fresh(i)
                || (surah_endpoint
                    && i + 1 == count
                    && matches[i].similarity >= STRONG_LEXICAL
                    && (context || count == 1))
                || (is_strong && (i + 1 < count || following))
                || (is_strong && (pause >= NATURAL_PAUSE || terminal) && (context || count == 1))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn word(s: &str, start: usize) -> WordEmission {
        WordEmission {
            text: s.into(),
            start,
            end: start + 1,
        }
    }
    #[test]
    fn expected_deletion_is_a_hard_boundary() {
        let decoded = vec![word("alpha", 0), word("gamma", 3)];
        let expected = vec!["alpha".into(), "beta".into(), "gamma".into()];
        assert_eq!(align(&decoded, &expected, 0, 0).words.len(), 1);
    }
    #[test]
    fn observed_frontier_cannot_be_replayed_as_fresh_evidence() {
        let matches = vec![
            WordMatch {
                decoded: 0,
                similarity: 0.8,
            },
            WordMatch {
                decoded: 1,
                similarity: 0.8,
            },
        ];
        let mut ledger = EvidenceLedger::default();
        for _ in 0..3 {
            ledger.observe(&matches, 16_000, 16_000);
        }
        ledger.observe(&matches, 19_200, 16_000);
        assert!(!ledger.confirmed(
            &matches,
            Boundary {
                count: 2,
                ..Default::default()
            }
        ));
        ledger.observe(&matches, 22_400, 19_200);
        assert!(ledger.confirmed(
            &matches,
            Boundary {
                count: 2,
                ..Default::default()
            }
        ));
    }
    #[test]
    fn verified_audio_fence_excludes_a_prior_identical_occurrence() {
        let decoded = vec![word("alpha", 1), word("beta", 3)];
        let expected = vec!["alpha".into(), "beta".into()];
        assert!(align(&decoded, &expected, 0, 5).words.is_empty());
    }
}
