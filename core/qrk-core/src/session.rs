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
    audio_cursor: u64,
    ledger: crate::continuous::EvidenceLedger,
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
            audio_cursor: 0,
            ledger: Default::default(),
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
        self.audio_cursor = 0;
        self.ledger = Default::default();
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
        if pcm.len() > 4800 {
            let mut events = Vec::new();
            for batch in pcm.chunks(4800) {
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
    fn context(&self, segment: &Segment) -> (Vec<(usize, usize)>, usize) {
        let surah = self.corpus.verses[segment.verse].surah;
        let mut back = Vec::new();
        let (mut verse, mut word) = (segment.verse, segment.from);
        for _ in 0..self.cfg.backtrack_words {
            if word > 0 {
                word -= 1;
            } else if verse > 0 && self.corpus.verses[verse - 1].surah == surah {
                verse -= 1;
                word = self.corpus.verses[verse].words.len() - 1;
            } else {
                break;
            }
            back.push((verse, word));
        }
        back.reverse();
        let anchor = back.len();
        let (mut verse, mut word) = (segment.verse, segment.from);
        for _ in 0..self.cfg.lookahead_words {
            if self.corpus.verses[verse].surah != surah {
                break;
            }
            back.push((verse, word));
            word += 1;
            if word == self.corpus.verses[verse].words.len() {
                verse += 1;
                word = 0;
                if verse == self.corpus.verses.len() {
                    break;
                }
            }
        }
        (back, anchor)
    }
    fn margin(
        &self,
        output: &AcousticOutput,
        frames: std::ops::Range<usize>,
        verse_index: usize,
        words: std::ops::Range<usize>,
        continuation: Option<&[u32]>,
    ) -> Result<f64> {
        let (start, end, from, to) = (frames.start, frames.end, words.start, words.end);
        if start >= end {
            return Ok(f64::NEG_INFINITY);
        }
        let verse = &self.corpus.verses[verse_index];
        let (tokens, ends) = verse.tokens_for(from..to);
        let mut targets = vec![tokens.clone()];
        if let Some((alt, _)) = text::alternate(verse.surah, verse.ayah, from, to, &tokens, &ends) {
            targets.push(alt);
        }
        // Swift ordinaryTargetTokenSequences: a fully evidenced current span
        // may include its canonical continuation; continuation alone stays a
        // negative comparator and cannot authorize skipping the current span.
        let mut negatives: BTreeSet<Vec<u32>> = BTreeSet::new();
        if let Some(next) = continuation {
            let extended: Vec<_> = targets
                .iter()
                .map(|t| [t.as_slice(), next].concat())
                .collect();
            targets.extend(extended);
            negatives.insert(next.to_vec());
        }
        let time = end - start;
        let scoped = &output.logits[start * output.vocab..end * output.vocab];
        let reachable = |t: &[u32]| t.len() + t.windows(2).filter(|p| p[0] == p[1]).count() <= time;
        let target_score = targets
            .iter()
            .filter(|t| reachable(t))
            .filter_map(|t| ctc::score(scoped, time, output.vocab, t, 1024).ok())
            .fold(f64::NEG_INFINITY, f64::max);
        let mut confuser = ctc::score(scoped, time, output.vocab, &[], 1024)?;
        for j in &verse.confusers {
            negatives.insert(self.corpus.verses[*j].tokens.clone());
        }
        for j in verse_index.saturating_sub(2)..(verse_index + 3).min(self.corpus.verses.len()) {
            if j != verse_index {
                negatives.insert(self.corpus.verses[j].tokens.clone());
            }
        }
        if to - from == 1 {
            for v in &self.corpus.verses {
                if v.words.len() == 1 {
                    negatives.insert(v.tokens.clone());
                }
            }
        }
        for word in 0..verse.words.len() {
            if !(from..to).contains(&word) {
                negatives.insert(verse.tokens_for(word..word + 1).0);
            }
        }
        for t in negatives {
            if !targets.contains(&t) && reachable(&t) {
                if let Ok(score) = ctc::score(scoped, time, output.vocab, &t, 1024) {
                    confuser = confuser.max(score);
                }
            }
        }
        Ok(target_score - confuser)
    }
    fn evaluate(&mut self, terminal: bool) -> Result<()> {
        let mut audio: Vec<f32> = self.audio.iter().copied().collect();
        let mut audio_start = self.total.saturating_sub(audio.len() as u64);
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
                let discarded = audio.len() - cap;
                audio.drain(..discarded);
                audio_start += discarded as u64;
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
        let words = ctc::word_emissions(&decoded.frames, &self.pieces, 1024);
        if self.transcript != decoded.text {
            self.transcript = decoded.text.clone();
            self.pending.push(Event::RawTranscript {
                text: self.transcript.clone(),
                confidence: ctc::transcript_confidence(
                    &output.logits,
                    output.time,
                    output.vocab,
                    1024,
                )?,
            });
        }
        let fresh = self.fresh.max(if terminal { 3200 } else { 0 });
        self.fresh = 0;
        let to_sample = |frame: usize| {
            audio_start + (frame as f64 / output.time as f64 * audio.len() as f64) as u64
        };
        let mut minimum = ((self
            .audio_cursor
            .saturating_sub(2400)
            .saturating_sub(audio_start)) as f64
            / audio.len() as f64
            * output.time as f64) as usize;
        for _ in 0..self.cfg.lookahead_words.min(128) {
            let Some(s) = self.segments.get(self.position).cloned() else {
                break;
            };
            let verse = self.corpus.verses[s.verse].clone();
            let (tokens, ends) = verse.tokens_for(s.from..s.to);
            let (locations, anchor) = self.context(&s);
            let expected: Vec<_> = locations
                .iter()
                .map(|(v, w)| self.corpus.verses[*v].words[*w].clone())
                .collect();
            let alignment = crate::continuous::align(&words, &expected, anchor, minimum);
            let count = s.to - s.from;
            let direct_count = alignment.words.len().min(count);
            let direct = &alignment.words[..direct_count];
            let mut progress = ctc::token_progress(&decoded.frames, &tokens, &ends, minimum, 1024);
            if let Some((alt, alt_ends)) =
                text::alternate(verse.surah, verse.ayah, s.from, s.to, &tokens, &ends)
            {
                let alternate =
                    ctc::token_progress(&decoded.frames, &alt, &alt_ends, minimum, 1024);
                if (alternate.words, alternate.matched_tokens)
                    > (progress.words, progress.matched_tokens)
                {
                    progress = alternate;
                }
            }
            let complete = if s.special.is_some() {
                progress.words == count
            } else {
                direct_count == count
            };
            let (start, mut end) = if s.special.is_some() {
                (progress.first.unwrap_or(minimum), output.time)
            } else if let Some(first) = direct.first() {
                (
                    words[first.decoded].start.saturating_sub(1).max(minimum),
                    if complete {
                        (words[direct.last().unwrap().decoded].end + 2).min(output.time)
                    } else {
                        output.time
                    },
                )
            } else {
                (minimum, output.time)
            };
            if start >= end {
                break;
            }
            let mut continuation = None;
            let mut following = false;
            if complete && s.special.is_none() {
                if let Some(next) = alignment.words.get(count) {
                    let &(v, w) = &locations[anchor + count];
                    let next_span = &words[next.decoded];
                    end = end.min(next_span.start);
                    let next_end = (next_span.end + 2).min(output.time);
                    let next_margin = self.margin(
                        &output,
                        next_span.start.saturating_sub(1)..next_end,
                        v,
                        w..w + 1,
                        None,
                    )?;
                    following = next_margin.is_finite() && next_margin >= 0.035;
                    if following {
                        continuation =
                            Some((self.corpus.verses[v].tokens_for(w..w + 1).0, next_end));
                    }
                }
            }
            let mut margin = self.margin(&output, start..end, s.verse, s.from..s.to, None)?;
            if let Some((next, extension_end)) = &continuation {
                let extended = self.margin(
                    &output,
                    start..*extension_end,
                    s.verse,
                    s.from..s.to,
                    Some(next),
                )?;
                // Current acoustics remain an independent gate, as in Swift's
                // primary-line decision; successor support never upgrades it.
                if margin >= 0.035 {
                    margin = margin.max(extended);
                }
            }
            let identity = if s.special.is_some() {
                decoded.tokens.ends_with(&tokens)
            } else {
                margin.is_finite() && margin >= 0.035
            };
            let confidence = if margin.is_finite() {
                -(-margin.max(0.)).exp_m1()
            } else {
                0.
            };
            let matches: BTreeSet<_> = (s.from
                ..s.from
                    + if s.special.is_some() {
                        progress.words
                    } else {
                        direct_count
                    })
                .collect();
            if !matches.is_empty() {
                let cumulative = self.matched.entry(verse.ayah).or_default();
                let prior = cumulative.clone();
                cumulative.extend(&matches);
                if *cumulative != prior {
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
            let speech = self.voice_end.saturating_sub(
                self.voice_start
                    .unwrap_or(self.voice_end)
                    .max(self.audio_cursor),
            ) as usize;
            let mut accepted = false;
            if s.special.is_some() {
                for tick in if terminal {
                    vec![6400, 9600, 12800]
                } else {
                    vec![silence]
                } {
                    accepted |= self.policy.evaluate(
                        AcceptanceEvidence {
                            word_count: count,
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
            } else if identity && complete && speech >= AcceptancePolicy::speech_floor(count) {
                self.ledger.observe(direct, self.total, self.voice_end);
                let surah_endpoint = s.to == verse.words.len()
                    && self.corpus.surahs[verse.surah as usize - 1].ayah_count == verse.ayah;
                let endpoint = !s.closes
                    || terminal
                    || silence >= crate::continuous::NATURAL_PAUSE
                    || following
                    || surah_endpoint;
                accepted = endpoint
                    && self.ledger.confirmed(
                        direct,
                        crate::continuous::Boundary {
                            count,
                            strong: margin >= 0.035 * 1.35,
                            following,
                            backtrack: alignment.backtrack,
                            pause: silence,
                            terminal,
                            surah_endpoint,
                        },
                    );
            }
            if !accepted {
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
            let endpoint_frame = if s.special.is_some() {
                progress.last.map_or(end, |f| f + 1)
            } else {
                words[direct.last().unwrap().decoded].end
            };
            let endpoint_sample = to_sample(endpoint_frame)
                .min(self.voice_end)
                .max(self.audio_cursor);
            if s.closes {
                let matched = VerseMatch {
                    surah: verse.surah,
                    ayah: verse.ayah,
                    confidence,
                    duration_seconds: endpoint_sample.saturating_sub(self.last_verse_sample) as f64
                        / 16000.,
                };
                self.verses.push(matched.clone());
                self.pending.push(Event::VerseMatch { verse: matched });
                self.last_verse_sample = endpoint_sample;
            }
            self.audio_cursor = endpoint_sample;
            minimum = endpoint_frame;
            self.position += 1;
            self.policy = AcceptancePolicy::default();
            self.ledger = Default::default();
            self.last_retry = None;
            // Keep only the bounded canonical backtrack, not an arbitrary tail.
            if !terminal {
                let kept = direct_count.saturating_sub(self.cfg.backtrack_words);
                let keep_frame = direct.get(kept).map_or(minimum, |m| words[m.decoded].start);
                let keep_from = to_sample(keep_frame.saturating_sub(2));
                let buffer_start = self.total.saturating_sub(self.audio.len() as u64);
                let discard = keep_from
                    .saturating_sub(buffer_start)
                    .min(self.audio.len() as u64) as usize;
                self.audio.drain(..discard);
            }
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
            // A constant stub that returns all 50 future words even for the
            // first 300 ms cannot exercise a bounded streaming recognizer.
            let (model, pcm) = if from == 0 && to == v.words.len() {
                super::continuous_fixture_tests::timeline(&c, s, &[a])
            } else {
                let mut frames = vec![1024; 4];
                for id in &tokens {
                    frames.extend([*id, *id, 1024]);
                }
                frames.extend([1024; 8]);
                super::continuous_fixture_tests::from_frames(frames)
            };
            let mut r = Recognizer::new(model, c.clone(), Config::default()).unwrap();
            r.set_expected(Target::Words {
                surah: s,
                ayah: a,
                from,
                to,
            })
            .unwrap();
            for block in pcm.chunks(4800) {
                r.feed(block);
            }
            assert_eq!(
                r.stop().unwrap().verses.len(),
                1,
                "target {s}:{a} words {from}..{to}"
            );
        }
    }
}

#[cfg(test)]
mod continuous_fixture_tests {
    use super::*;
    #[derive(serde::Deserialize)]
    struct Schedule {
        surah: u16,
        ayahs: Vec<u16>,
        frame_samples: usize,
        initial_blank_frames: usize,
        token_repeat_frames: usize,
        separator_blank_frames: usize,
        trailing_blank_frames: usize,
        winner_logit: f32,
        other_logit: f32,
    }
    pub(super) struct Timeline {
        frames: Vec<u32>,
        stride: usize,
        winner: f32,
        other: f32,
    }
    impl AcousticModel for Timeline {
        fn infer(&mut self, pcm: &[f32]) -> Result<AcousticOutput> {
            let start = pcm
                .iter()
                .enumerate()
                .find(|(_, v)| **v > 0.)
                .map_or(0, |(i, v)| {
                    ((*v as f64 * 1_000_000.).round() as usize).saturating_sub(i + 1)
                });
            let time = pcm.len().div_ceil(self.stride);
            let normalizer =
                ((self.winner as f64).exp() + 1024. * (self.other as f64).exp()).ln() as f32;
            let mut logits = vec![self.other - normalizer; time * 1025];
            for i in 0..time {
                let id = self
                    .frames
                    .get((start + i * self.stride) / self.stride)
                    .copied()
                    .unwrap_or(1024);
                logits[i * 1025 + id as usize] = self.winner - normalizer;
            }
            Ok(AcousticOutput {
                logits,
                time,
                vocab: 1025,
            })
        }
    }
    pub(super) fn timeline(c: &CorpusIndex, surah: u16, ayahs: &[u16]) -> (Timeline, Vec<f32>) {
        let s: Schedule =
            serde_json::from_str(include_str!("../../../tests/fixtures/two-ayah-stream.json"))
                .unwrap();
        let mut frames = vec![1024; s.initial_blank_frames];
        for ayah in ayahs {
            for id in &c.verse(surah, *ayah).unwrap().tokens {
                frames.extend(std::iter::repeat_n(*id, s.token_repeat_frames));
                frames.extend(std::iter::repeat_n(1024, s.separator_blank_frames));
            }
        }
        let spoken = frames.len() * s.frame_samples;
        frames.extend(std::iter::repeat_n(1024, s.trailing_blank_frames));
        let mut pcm: Vec<_> = (0..spoken).map(|i| (i + 1) as f32 / 1_000_000.).collect();
        pcm.resize(frames.len() * s.frame_samples, 0.);
        (
            Timeline {
                frames,
                stride: s.frame_samples,
                winner: s.winner_logit,
                other: s.other_logit,
            },
            pcm,
        )
    }
    pub(super) fn from_frames(frames: Vec<u32>) -> (Timeline, Vec<f32>) {
        let s: Schedule =
            serde_json::from_str(include_str!("../../../tests/fixtures/two-ayah-stream.json"))
                .unwrap();
        let spoken = frames
            .iter()
            .rposition(|x| *x != 1024)
            .map_or(0, |i| (i + 1) * s.frame_samples);
        let mut pcm: Vec<_> = (0..spoken).map(|i| (i + 1) as f32 / 1_000_000.).collect();
        pcm.resize(frames.len() * s.frame_samples, 0.);
        (
            Timeline {
                frames,
                stride: s.frame_samples,
                winner: s.winner_logit,
                other: s.other_logit,
            },
            pcm,
        )
    }
    fn fixture(target: Target, live: bool) -> (Summary, Vec<Event>) {
        let c = crate::corpus::test_index();
        let s: Schedule =
            serde_json::from_str(include_str!("../../../tests/fixtures/two-ayah-stream.json"))
                .unwrap();
        let (model, pcm) = timeline(&c, s.surah, &s.ayahs);
        let mut r = Recognizer::new(
            model,
            c,
            Config {
                live_tracking: live,
                ..Default::default()
            },
        )
        .unwrap();
        r.set_expected(target).unwrap();
        let mut events = Vec::new();
        for block in pcm.chunks(4800) {
            events.extend(r.feed(block));
        }
        let summary = r.stop().unwrap();
        (summary, events)
    }
    #[test]
    fn continuous_two_ayah_fixture_advances_before_stop() {
        let (summary, events) = fixture(
            Target::Ayahs {
                surah: 78,
                from: 1,
                to: 2,
            },
            true,
        );
        assert!(
            events
                .iter()
                .any(|e| matches!(e, Event::VerseMatch { verse } if verse.ayah==1)),
            "first ayah must commit while streaming"
        );
        assert!(
            events
                .iter()
                .any(|e| matches!(e, Event::WordProgress { ayah: 2, .. })),
            "cursor must advance"
        );
        assert_eq!(
            summary
                .verses
                .iter()
                .map(|v| (v.surah, v.ayah))
                .collect::<Vec<_>>(),
            [(78, 1), (78, 2)]
        );
    }
    #[test]
    fn selected_ayah_survives_continuing_speech() {
        let (summary, events) = fixture(
            Target::Ayahs {
                surah: 78,
                from: 1,
                to: 1,
            },
            true,
        );
        assert!(events
            .iter()
            .any(|e| matches!(e, Event::VerseMatch { verse } if verse.ayah==1)));
        assert_eq!(
            summary.verses.iter().map(|v| v.ayah).collect::<Vec<_>>(),
            [1]
        );
    }
    #[test]
    fn stop_scores_each_ayah_segment_not_only_the_tail() {
        let (summary, _) = fixture(
            Target::Ayahs {
                surah: 78,
                from: 1,
                to: 2,
            },
            false,
        );
        assert_eq!(
            summary.verses.iter().map(|v| v.ayah).collect::<Vec<_>>(),
            [1, 2]
        );
    }
    #[test]
    fn continuous_wrong_target_stays_rejected() {
        let (summary, _) = fixture(Target::Surah(1), true);
        assert!(summary.verses.is_empty());
        assert!(summary
            .events
            .iter()
            .any(|e| matches!(e, Event::NeedsRetry { .. })));
    }
    #[test]
    fn continuous_surah_stream_matches_four_ayahs_without_reset() {
        let c = crate::corpus::test_index();
        let (model, pcm) = timeline(&c, 112, &[1, 2, 3, 4]);
        let mut r = Recognizer::new(model, c, Config::default()).unwrap();
        r.set_expected(Target::surah(112)).unwrap();
        for chunk in pcm.chunks(4800) {
            r.feed(chunk);
        }
        assert_eq!(
            r.stop()
                .unwrap()
                .verses
                .iter()
                .map(|v| v.ayah)
                .collect::<Vec<_>>(),
            [1, 2, 3, 4]
        );
    }
    #[test]
    fn a_prior_identical_ayah_cannot_be_credited_twice() {
        let original = crate::corpus::test_index();
        let mut c = (*original).clone();
        let first = c.verse_index(78, 1).unwrap();
        let next = c.verse_index(78, 2).unwrap();
        let mut repeated = c.verses[first].clone();
        repeated.ayah = 2;
        c.verses[next] = repeated;
        let (model, pcm) = timeline(&c, 78, &[1]);
        let mut r = Recognizer::new(model, Arc::new(c), Config::default()).unwrap();
        r.set_expected(Target::Ayahs {
            surah: 78,
            from: 1,
            to: 2,
        })
        .unwrap();
        for chunk in pcm.chunks(4800) {
            r.feed(chunk);
        }
        let first_stop = r.stop().unwrap();
        let second_stop = r.stop().unwrap();
        assert_eq!(
            first_stop.verses.iter().map(|v| v.ayah).collect::<Vec<_>>(),
            [1]
        );
        assert_eq!(first_stop.verses, second_stop.verses);
        assert!(!second_stop
            .events
            .iter()
            .any(|e| matches!(e, Event::VerseMatch { .. })));
    }
    #[test]
    fn long_ayah_tracks_through_a_bounded_rolling_window() {
        let c = crate::corpus::test_index();
        let (model, pcm) = timeline(&c, 2, &[255]);
        assert!(
            pcm.len() > 192000,
            "fixture must exceed the retained window"
        );
        let mut r = Recognizer::new(model, c, Config::default()).unwrap();
        r.set_expected(Target::Ayahs {
            surah: 2,
            from: 255,
            to: 255,
        })
        .unwrap();
        for chunk in pcm.chunks(4800) {
            r.feed(chunk);
        }
        assert_eq!(
            r.stop()
                .unwrap()
                .verses
                .iter()
                .map(|v| v.ayah)
                .collect::<Vec<_>>(),
            [255]
        );
    }
}
