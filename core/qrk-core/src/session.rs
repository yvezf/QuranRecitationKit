use crate::{
    corpus::CorpusIndex, ctc, text, Config, Error, Event, Policy, Result, RetryReason, State,
    Summary, Target, VerseMatch,
};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    sync::Arc,
};
#[derive(Clone, Debug)]
pub struct AcousticOutput {
    pub logits: Vec<f32>,
    pub time: usize,
    pub vocab: usize,
}
pub trait AcousticModel: Send {
    fn infer(&mut self, pcm16k: &[f32]) -> Result<AcousticOutput>;
}
#[derive(Clone, Debug)]
struct Segment {
    verse: usize,
    from: usize,
    to: usize,
    closes: bool,
    special: Option<usize>,
}
#[derive(Clone, Debug, Default)]
pub struct AcceptancePolicy {
    last_marker: Option<u64>,
    stable: usize,
}
pub struct AcceptanceEvidence<'a> {
    pub word_count: usize,
    pub matches: &'a BTreeSet<usize>,
    pub range: std::ops::Range<usize>,
    pub identity: bool,
    pub speech: usize,
    pub fresh: usize,
    pub silence: usize,
    pub marker: u64,
}
impl AcceptancePolicy {
    pub fn evaluate(
        &mut self,
        e: AcceptanceEvidence<'_>,
        policy: Policy,
        special: Option<usize>,
    ) -> bool {
        let required = if e.word_count <= 4 || policy == Policy::Conservative {
            e.word_count
        } else {
            e.word_count - 1
        };
        let floor = special
            .map(|letters| {
                [6400, 16800, 23200, 28800, 33600, 37600, 40000, 42400]
                    [letters.saturating_sub(1).min(7)]
            })
            .unwrap_or_else(|| Self::speech_floor(e.word_count));
        let endpoint = e.matches.contains(&(e.range.end - 1));
        let prefix = e
            .range
            .clone()
            .take_while(|n| e.matches.contains(n))
            .count();
        let qualifies = e.identity
            && e.matches.len() >= required
            && endpoint
            && (e.word_count > 4 || prefix == e.word_count)
            && e.speech >= floor
            && e.fresh >= 3200
            && e.silence
                >= (if policy == Policy::Lenient && special.is_none() {
                    3200
                } else {
                    6400
                })
            && e.silence <= 32000;
        if qualifies {
            if self.last_marker == Some(e.marker) {
                self.stable += 1
            } else {
                self.stable = 1;
                self.last_marker = Some(e.marker)
            }
        } else {
            self.stable = 0;
            self.last_marker = None;
        }
        qualifies
            && self.stable
                >= (if special.is_some() {
                    3
                } else if policy == Policy::Conservative {
                    2
                } else {
                    1
                })
    }
    pub fn speech_floor(words: usize) -> usize {
        const FLOORS: [usize; 8] = [4800, 8000, 11200, 13600, 16000, 18400, 20800, 23200];
        if words <= 8 {
            FLOORS[words.max(1) - 1]
        } else {
            23200 + (words - 8) * 2400
        }
    }
}
pub struct Recognizer<M: AcousticModel> {
    model: M,
    pub corpus: Arc<CorpusIndex>,
    cfg: Config,
    pieces: Vec<String>,
    segments: Vec<Segment>,
    position: usize,
    audio: VecDeque<f32>,
    total: u64,
    voice_end: u64,
    voice_start: Option<u64>,
    fresh: usize,
    verses: Vec<VerseMatch>,
    accepted: Vec<String>,
    transcript: String,
    pending: Vec<Event>,
    matched: BTreeMap<u16, BTreeSet<usize>>,
    policy: AcceptancePolicy,
    ended: bool,
    last_error: Option<Error>,
    last_verse_sample: u64,
    last_retry: Option<(u64, RetryReason)>,
}
impl<M: AcousticModel> Recognizer<M> {
    pub fn new(model: M, corpus: Arc<CorpusIndex>, cfg: Config) -> Result<Self> {
        cfg.validate()?;
        let vocabulary: BTreeMap<String, String> =
            serde_json::from_str(include_str!("../../../model/vocab.json"))
                .map_err(|e| Error::Corpus(e.to_string()))?;
        let mut pieces = vec![String::new(); 1025];
        for (i, p) in vocabulary {
            let id = i
                .parse::<usize>()
                .map_err(|e| Error::Corpus(e.to_string()))?;
            if id >= 1025 {
                return Err(Error::Corpus("vocabulary shape mismatch".into()));
            }
            pieces[id] = p;
        }
        Ok(Self {
            model,
            corpus,
            cfg,
            pieces,
            segments: vec![],
            position: 0,
            audio: VecDeque::with_capacity(192000),
            total: 0,
            voice_end: 0,
            voice_start: None,
            fresh: 0,
            verses: vec![],
            accepted: vec![],
            transcript: String::new(),
            pending: vec![Event::State { state: State::Idle }],
            matched: BTreeMap::new(),
            policy: AcceptancePolicy::default(),
            ended: true,
            last_error: None,
            last_verse_sample: 0,
            last_retry: None,
        })
    }
    pub fn set_expected(&mut self, target: Target) -> Result<()> {
        let (surah, from, to, words) = match target {
            Target::Surah(surah) => {
                let info = self
                    .corpus
                    .surahs
                    .iter()
                    .find(|s| s.number == surah)
                    .ok_or_else(|| Error::Invalid("unknown surah".into()))?;
                (surah, 1, info.ayah_count, None)
            }
            Target::Ayahs { surah, from, to } => (surah, from, to, None),
            Target::Words {
                surah,
                ayah,
                from,
                to,
            } => (surah, ayah, ayah, Some(from..to)),
        };
        if from == 0 || from > to {
            return Err(Error::Invalid("invalid ayah range".into()));
        }
        let mut segments = vec![];
        for ayah in from..=to {
            let index = self
                .corpus
                .verse_index(surah, ayah)
                .ok_or_else(|| Error::Invalid("unknown ayah".into()))?;
            let v = &self.corpus.verses[index];
            let range = words.clone().unwrap_or(0..v.words.len());
            if range.start >= range.end || range.end > v.words.len() {
                return Err(Error::Invalid("invalid word range".into()));
            }
            let width = 8.min(self.cfg.lookahead_words);
            let mut start = range.start;
            while start < range.end {
                let end = (start + width).min(range.end);
                let special = muqattaat(v.surah, v.ayah, start, end, &v.tokens)?;
                segments.push(Segment {
                    verse: index,
                    from: start,
                    to: end,
                    closes: end == range.end,
                    special,
                });
                start = end;
            }
        }
        self.reset();
        self.pending.clear();
        self.segments = segments;
        self.ended = false;
        self.pending.push(Event::State {
            state: State::Listening,
        });
        Ok(())
    }
    pub fn reset(&mut self) {
        self.segments.clear();
        self.position = 0;
        self.audio.clear();
        self.total = 0;
        self.voice_end = 0;
        self.voice_start = None;
        self.fresh = 0;
        self.verses.clear();
        self.accepted.clear();
        self.transcript.clear();
        self.pending.clear();
        self.pending.push(Event::State { state: State::Idle });
        self.matched.clear();
        self.policy = AcceptancePolicy::default();
        self.ended = true;
        self.last_error = None;
        self.last_verse_sample = 0;
        self.last_retry = None;
    }
    pub fn feed(&mut self, pcm: &[f32]) -> Vec<Event> {
        if self.ended {
            return std::mem::take(&mut self.pending);
        }
        if pcm.iter().any(|x| !x.is_finite()) {
            self.last_error = Some(Error::Invalid("non-finite PCM".into()));
            return vec![Event::NeedsRetry {
                reason: RetryReason::Inconclusive,
            }];
        }
        let cap = (self.cfg.maximum_window_seconds * 16000.) as usize;
        // Large caller batches must not erase their opening before any inference.
        if pcm.len() > cap / 2 {
            let mut events = Vec::new();
            for batch in pcm.chunks(cap / 2) {
                events.extend(self.feed(batch));
            }
            return events;
        }
        for chunk in pcm.chunks(160) {
            self.total += chunk.len() as u64;
            self.fresh += chunk.len();
            let rms = (chunk.iter().map(|x| x * x).sum::<f32>() / chunk.len() as f32).sqrt();
            if rms > 0.004 {
                self.voice_start
                    .get_or_insert(self.total - chunk.len() as u64);
                self.voice_end = self.total;
            }
            self.audio.extend(chunk);
            if self.audio.len() > cap {
                self.audio.drain(..self.audio.len() - cap);
            }
        }
        if self.position < self.segments.len()
            && self.voice_start.is_some()
            && self.fresh >= 3200
            && (self.cfg.live_tracking || self.total - self.voice_end >= 6400)
        {
            if let Err(e) = self.evaluate(false) {
                self.last_error = Some(e);
                self.retry(RetryReason::Inconclusive);
            }
        }
        std::mem::take(&mut self.pending)
    }
    fn evaluate(&mut self, terminal: bool) -> Result<()> {
        let mut audio: Vec<f32> = self.audio.iter().copied().collect();
        let actual_silence = (self.total - self.voice_end) as usize;
        let silence = if terminal {
            actual_silence.clamp(12800, 32000)
        } else {
            actual_silence
        };
        if terminal && actual_silence < 12800 {
            audio.resize(audio.len() + 12800 - actual_silence, 0.);
            let cap = (self.cfg.maximum_window_seconds * 16000.) as usize;
            if audio.len() > cap {
                audio.drain(..audio.len() - cap);
            }
        }
        if audio.is_empty() {
            return Ok(());
        }
        let output = self.model.infer(&audio)?;
        let decoded = ctc::decode(
            &output.logits,
            output.time,
            output.vocab,
            &self.pieces,
            1024,
        )?;
        if self.transcript != decoded.text {
            self.transcript = decoded.text.clone();
            self.pending.push(Event::RawTranscript {
                text: self.transcript.clone(),
                confidence: 0.,
            });
        }
        let speech =
            self.voice_end
                .saturating_sub(self.voice_start.unwrap_or(self.voice_end)) as usize;
        let fresh = self.fresh.max(if terminal { 3200 } else { 0 });
        self.fresh = 0;
        let mut minimum = 0;
        for _ in 0..self.cfg.lookahead_words.min(32) {
            let Some(s) = self.segments.get(self.position).cloned() else {
                break;
            };
            let verse = self.corpus.verses[s.verse].clone();
            let (tokens, ends) = verse.tokens_for(s.from..s.to);
            let mut variants = vec![(tokens.clone(), ends.clone())];
            if let Some(alt) =
                text::alternate(verse.surah, verse.ayah, s.from, s.to, &tokens, &ends)
            {
                variants.push(alt);
            }
            let progress = variants
                .iter()
                .map(|(t, e)| ctc::token_progress(&decoded.frames, t, e, minimum, 1024))
                .max_by_key(|p| (p.words, p.matched_tokens))
                .unwrap_or_default();
            let complete = progress.words == s.to - s.from;
            let start = if complete {
                progress.first.unwrap_or(minimum)
            } else {
                minimum
            };
            let end = if complete && s.special.is_none() {
                (progress.last.unwrap_or(output.time - 1) + 2).min(output.time)
            } else {
                output.time
            };
            if start >= end {
                break;
            }
            let scoped = &output.logits[start * output.vocab..end * output.vocab];
            let time = end - start;
            let local_decoded = ctc::decode(scoped, time, output.vocab, &self.pieces, 1024)?;
            let mut matches = text::align_words(&local_decoded.text, &verse.words, s.from, s.to);
            for word in s.from..s.from + progress.words {
                matches.insert(word);
            }
            let reachable =
                |t: &[u32]| t.len() + t.windows(2).filter(|p| p[0] == p[1]).count() <= time;
            let target_score = variants
                .iter()
                .filter(|v| reachable(&v.0))
                .filter_map(|v| ctc::score(scoped, time, output.vocab, &v.0, 1024).ok())
                .fold(f64::NEG_INFINITY, f64::max);
            let mut confuser_score = ctc::score(scoped, time, output.vocab, &[], 1024)?;
            let mut negatives: BTreeSet<Vec<u32>> = BTreeSet::new();
            for j in &verse.confusers {
                negatives.insert(self.corpus.verses[*j].tokens.clone());
            }
            for j in s.verse.saturating_sub(2)..(s.verse + 3).min(self.corpus.verses.len()) {
                if j != s.verse {
                    negatives.insert(self.corpus.verses[j].tokens.clone());
                }
            }
            if s.to - s.from == 1 {
                for v in &self.corpus.verses {
                    if v.words.len() == 1 {
                        negatives.insert(v.tokens.clone());
                    }
                }
            }
            for word in 0..verse.words.len() {
                if !(s.from..s.to).contains(&word) {
                    negatives.insert(verse.tokens_for(word..word + 1).0);
                }
            }
            for t in negatives {
                if !variants.iter().any(|v| v.0 == t) && reachable(&t) {
                    if let Ok(score) = ctc::score(scoped, time, output.vocab, &t, 1024) {
                        confuser_score = confuser_score.max(score);
                    }
                }
            }
            let margin = target_score - confuser_score;
            let identity = if s.special.is_some() {
                decoded.tokens.ends_with(&tokens)
            } else {
                margin.is_finite() && margin >= 0.035
            };
            let confidence = if margin.is_finite() {
                margin.clamp(0., 1.)
            } else {
                0.
            };
            if !matches.is_empty() {
                let cumulative = self.matched.entry(verse.ayah).or_default();
                let previous = cumulative.clone();
                cumulative.extend(matches.iter());
                if *cumulative != previous {
                    self.pending.push(Event::WordProgress {
                        surah: verse.surah,
                        ayah: verse.ayah,
                        word_index: *matches.last().unwrap(),
                        total_words: verse.words.len(),
                        matched_word_indices: cumulative.iter().copied().collect(),
                        confidence,
                    });
                }
            }
            let mut accepted = false;
            let ticks = if terminal {
                vec![6400, 9600, 12800]
            } else {
                vec![silence]
            };
            for tick in ticks {
                accepted |= self.policy.evaluate(
                    AcceptanceEvidence {
                        word_count: s.to - s.from,
                        matches: &matches,
                        range: s.from..s.to,
                        identity,
                        speech,
                        fresh,
                        silence: tick,
                        marker: self.voice_end,
                    },
                    self.cfg.policy,
                    s.special,
                );
            }
            let internal = !s.closes
                && identity
                && complete
                && matches.len() == s.to - s.from
                && speech >= AcceptancePolicy::speech_floor(s.to - s.from);
            if !accepted && !internal {
                if terminal || silence > 32000 {
                    self.retry(if speech < 4800 {
                        RetryReason::TooShort
                    } else if decoded.text.is_empty() {
                        RetryReason::Noise
                    } else if !identity {
                        RetryReason::OffTarget
                    } else {
                        RetryReason::Inconclusive
                    });
                }
                break;
            }
            self.accepted.push(verse.words[s.from..s.to].join(" "));
            if s.closes {
                let matched = VerseMatch {
                    surah: verse.surah,
                    ayah: verse.ayah,
                    confidence,
                    duration_seconds: self.voice_end.saturating_sub(self.last_verse_sample) as f64
                        / 16000.,
                };
                self.verses.push(matched.clone());
                self.pending.push(Event::VerseMatch { verse: matched });
                self.last_verse_sample = self.voice_end;
            }
            minimum = progress.last.map_or(end, |n| n + 1);
            if !terminal {
                // Retain approximate, token-timed backtrack context without letting it move the verified cursor.
                let kept_words = self.cfg.backtrack_words.min(ends.len());
                let kept_tokens = if kept_words == 0 {
                    0
                } else {
                    tokens.len()
                        - if kept_words == ends.len() {
                            0
                        } else {
                            ends[ends.len() - kept_words - 1]
                        }
                };
                let keep_frame = minimum.saturating_sub(kept_tokens * 2);
                let original_start = self.total.saturating_sub(audio.len() as u64);
                let keep_from = original_start
                    + (keep_frame as f64 / output.time as f64 * audio.len() as f64) as u64;
                let buffer_start = self.total.saturating_sub(self.audio.len() as u64);
                let discard = keep_from
                    .saturating_sub(buffer_start)
                    .min(self.audio.len() as u64) as usize;
                self.audio.drain(..discard);
            }
            self.position += 1;
            self.policy = AcceptancePolicy::default();
        }
        Ok(())
    }
    fn retry(&mut self, reason: RetryReason) {
        if self.last_retry != Some((self.voice_end, reason)) {
            self.pending.push(Event::NeedsRetry { reason });
            self.last_retry = Some((self.voice_end, reason));
        }
    }
    pub fn stop(&mut self) -> Result<Summary> {
        if !self.ended {
            self.pending.push(Event::State {
                state: State::Evaluating,
            });
            if self.voice_start.is_some() && self.position < self.segments.len() {
                self.evaluate(true)?;
            } else if self.voice_start.is_none() {
                self.retry(if self.total < 4800 {
                    RetryReason::TooShort
                } else {
                    RetryReason::Noise
                });
            }
            self.ended = true;
            self.pending.push(Event::State {
                state: State::Ended,
            });
        }
        if let Some(error) = self.last_error.take() {
            return Err(error);
        }
        Ok(Summary {
            kind: crate::types::SummaryType::Summary,
            verses: self.verses.clone(),
            transcript: if self.accepted.is_empty() {
                self.transcript.clone()
            } else {
                self.accepted.join(" ")
            },
            duration: self.total as f64 / 16000.,
            events: std::mem::take(&mut self.pending),
        })
    }
}
/// Frozen standalone disconnected-letter targets; ordinary mixed-text ayahs use the normal policy.
fn muqattaat(
    surah: u16,
    ayah: u16,
    from: usize,
    to: usize,
    tokens: &[u32],
) -> Result<Option<usize>> {
    if from != 0 || to != 1 {
        return Ok(None);
    }
    let profile: Option<(&[u32], usize)> = match (surah, ayah) {
        (2 | 3 | 29 | 30 | 31 | 32, 1) => Some((&[31], 3)),
        (7, 1) => Some((&[31, 45], 4)),
        (19, 1) => Some((&[95, 3, 2, 13, 45], 5)),
        (20, 1) => Some((&[133, 3], 2)),
        (26 | 28, 1) => Some((&[133, 26, 7], 3)),
        (36, 1) => Some((&[22, 26], 2)),
        (40..=46, 1) => Some((&[73, 7], 2)),
        (42, 2) => Some((&[66, 26, 32], 3)),
        _ => None,
    };
    if let Some((expected, letters)) = profile {
        if tokens != expected {
            return Err(Error::Corpus(
                "disconnected-letter token contract mismatch".into(),
            ));
        }
        Ok(Some(letters))
    } else {
        Ok(None)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Stub(AcousticOutput);
    impl AcousticModel for Stub {
        fn infer(&mut self, _: &[f32]) -> Result<AcousticOutput> {
            Ok(self.0.clone())
        }
    }
    fn synthetic(tokens: &[u32]) -> AcousticOutput {
        let mut frames = vec![1024];
        for t in tokens {
            frames.extend([*t, *t, 1024]);
        }
        frames.extend([1024; 4]);
        let mut logits = vec![-12.; frames.len() * 1025];
        for (t, id) in frames.iter().enumerate() {
            logits[t * 1025 + *id as usize] = -0.001;
        }
        AcousticOutput {
            logits,
            time: frames.len(),
            vocab: 1025,
        }
    }
    #[test]
    fn ikhlas_events() {
        let c = crate::corpus::test_index();
        let tokens: Vec<_> = c
            .verses
            .iter()
            .filter(|v| v.surah == 112)
            .flat_map(|v| v.tokens.clone())
            .collect();
        let mut r = Recognizer::new(Stub(synthetic(&tokens)), c, Config::default()).unwrap();
        r.set_expected(Target::surah(112)).unwrap();
        let mut events = r.feed(&vec![0.1; 64000]);
        let summary = r.stop().unwrap();
        events.extend(summary.events);
        assert_eq!(
            summary.verses.iter().map(|v| v.ayah).collect::<Vec<_>>(),
            vec![1, 2, 3, 4]
        );
        assert!(events
            .iter()
            .any(|e| matches!(e, Event::WordProgress { .. })));
    }
    #[test]
    fn noise_never_accuses() {
        let c = crate::corpus::test_index();
        let mut r = Recognizer::new(Stub(synthetic(&[])), c, Config::default()).unwrap();
        r.set_expected(Target::surah(112)).unwrap();
        r.feed(&[0.; 100]);
        let s = r.stop().unwrap();
        assert!(s.verses.is_empty());
        assert!(s.events.contains(&Event::NeedsRetry {
            reason: RetryReason::TooShort
        }));
    }
    #[test]
    fn acceptance_requires_identity() {
        let mut p = AcceptancePolicy::default();
        let matches = BTreeSet::from([0, 1, 2, 3]);
        for _ in 0..4 {
            assert!(!p.evaluate(
                AcceptanceEvidence {
                    word_count: 4,
                    matches: &matches,
                    range: 0..4,
                    identity: false,
                    speech: 16000,
                    fresh: 3200,
                    silence: 6400,
                    marker: 16000
                },
                Policy::Balanced,
                None
            ));
        }
    }
}
#[cfg(test)]
mod extended_tests {
    use super::*;
    struct Stub(AcousticOutput);
    impl AcousticModel for Stub {
        fn infer(&mut self, _: &[f32]) -> Result<AcousticOutput> {
            Ok(self.0.clone())
        }
    }
    fn output(tokens: &[u32]) -> AcousticOutput {
        let mut frames = vec![1024];
        for t in tokens {
            frames.extend([*t, *t, 1024]);
        }
        frames.extend([1024; 4]);
        let mut logits = vec![-12.; frames.len() * 1025];
        for (i, t) in frames.iter().enumerate() {
            logits[i * 1025 + *t as usize] = -0.001;
        }
        AcousticOutput {
            logits,
            time: frames.len(),
            vocab: 1025,
        }
    }
    #[test]
    fn all_standalone_letter_endpoints() {
        let c = crate::corpus::test_index();
        let mut count = 0;
        for v in &c.verses {
            if let Some(letters) = muqattaat(v.surah, v.ayah, 0, v.words.len(), &v.tokens).unwrap()
            {
                count += 1;
                let mut r =
                    Recognizer::new(Stub(output(&v.tokens)), c.clone(), Config::default()).unwrap();
                r.set_expected(Target::Ayahs {
                    surah: v.surah,
                    from: v.ayah,
                    to: v.ayah,
                })
                .unwrap();
                r.feed(&vec![0.1; 64000]);
                let s = r.stop().unwrap();
                assert_eq!(
                    s.verses.len(),
                    1,
                    "{}:{} {} letters",
                    v.surah,
                    v.ayah,
                    letters
                );
            }
        }
        assert_eq!(count, 20);
    }
    #[test]
    fn proper_letter_prefix_is_not_complete() {
        let c = crate::corpus::test_index();
        let mut r = Recognizer::new(Stub(output(&[31, 45])), c, Config::default()).unwrap();
        r.set_expected(Target::Ayahs {
            surah: 2,
            from: 1,
            to: 1,
        })
        .unwrap();
        r.feed(&vec![0.1; 64000]);
        assert!(r.stop().unwrap().verses.is_empty());
    }
    #[test]
    fn wrong_surah_and_noise_never_complete() {
        let c = crate::corpus::test_index();
        let tokens = c.verse(1, 1).unwrap().tokens.clone();
        let mut r = Recognizer::new(Stub(output(&tokens)), c, Config::default()).unwrap();
        r.set_expected(Target::Surah(112)).unwrap();
        r.feed(&vec![0.1; 64000]);
        let s = r.stop().unwrap();
        assert!(s.verses.is_empty());
        assert!(s
            .events
            .iter()
            .any(|e| matches!(e, Event::NeedsRetry { .. })));
    }
    #[test]
    fn partial_and_long_ayah_targets() {
        let c = crate::corpus::test_index();
        for (s, a, from, to) in [
            (1, 7, 4, 9),
            (2, 255, 0, c.verse(2, 255).unwrap().words.len()),
        ] {
            let v = c.verse(s, a).unwrap();
            let (tokens, _) = v.tokens_for(from..to);
            let mut r =
                Recognizer::new(Stub(output(&tokens)), c.clone(), Config::default()).unwrap();
            r.set_expected(Target::Words {
                surah: s,
                ayah: a,
                from,
                to,
            })
            .unwrap();
            r.feed(&vec![0.1; 128000]);
            assert_eq!(r.stop().unwrap().verses.len(), 1);
        }
    }
}
