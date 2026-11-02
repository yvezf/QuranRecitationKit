//! Open-set retrieval → scoped CTC rerank, following Tilawa's MIT two-stage design.
//! Search indices are runtime data; display text is sliced from verbatim Tanzil.
use crate::{
    ctc, text, AcousticModel, AcousticOutput, CorpusIndex, Error, Event, Result, State, Summary,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, VecDeque},
    ops::Range,
    sync::Arc,
};
const RATE: usize = 16_000;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct SpotConfig {
    pub window_seconds: f64,
    pub min_words: usize,
    pub min_seconds: f64,
    pub min_margin: f64,
    pub high_margin: f64,
    pub ambiguity_margin: f64,
    pub max_candidates: usize,
}
impl Default for SpotConfig {
    fn default() -> Self {
        Self {
            window_seconds: 8.,
            min_words: 3,
            min_seconds: 1.5,
            min_margin: 0.035,
            high_margin: 0.20,
            ambiguity_margin: 0.05,
            max_candidates: 8,
        }
    }
}
impl SpotConfig {
    pub fn validate(&self) -> Result<()> {
        if !self.window_seconds.is_finite()
            || !(6. ..=12.).contains(&self.window_seconds)
            || !(3..=32).contains(&self.min_words)
            || !self.min_seconds.is_finite()
            || !(1.5..=12.).contains(&self.min_seconds)
            || self.min_seconds > self.window_seconds
            || !self.min_margin.is_finite()
            || !(0.035..=10.).contains(&self.min_margin)
            || !self.high_margin.is_finite()
            || self.high_margin < self.min_margin.max(0.20)
            || !self.ambiguity_margin.is_finite()
            || !(0. ..=1.).contains(&self.ambiguity_margin)
            || !(2..=32).contains(&self.max_candidates)
        {
            return Err(Error::Invalid("invalid spotting configuration".into()));
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct QuoteCandidate {
    pub surah: u16,
    pub ayah_from: u16,
    pub ayah_to: u16,
    /// Zero-based, half-open offsets in the first/last ayah respectively.
    pub word_from: usize,
    pub word_to: usize,
    pub confidence: f64,
    pub text_uthmani: String,
    pub reference: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct QuoteDetected {
    /// Ambiguous detections have no selected citation: inspect candidates instead.
    pub surah: Option<u16>,
    pub ayah_from: Option<u16>,
    pub ayah_to: Option<u16>,
    pub word_from: Option<usize>,
    pub word_to: Option<usize>,
    pub start_seconds: f64,
    pub end_seconds: f64,
    pub confidence: f64,
    pub text_uthmani: Option<String>,
    pub reference: Option<String>,
    pub verified: bool,
    pub ambiguous: bool,
    pub candidates: Vec<QuoteCandidate>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TextMatch {
    pub verified: bool,
    pub ambiguous: bool,
    pub candidates: Vec<QuoteCandidate>,
}
#[derive(Clone, Serialize, Deserialize)]
struct Word {
    verse: usize,
    local: usize,
    key: String,
}
#[derive(Clone, Debug)]
struct Hit {
    span: Range<usize>,
    query: Range<usize>,
    strength: usize,
}
pub struct SpotIndex {
    pub corpus: Arc<CorpusIndex>,
    words: Vec<Word>,
    starts: Vec<usize>,
    unigrams: HashMap<String, Vec<usize>>,
    trigrams: HashMap<String, Vec<usize>>,
    bigrams: HashMap<String, Vec<usize>>,
}
fn key(s: &str) -> String {
    text::letters(&text::normalize_arabic(s)).replace('ء', "")
}
fn shingle(words: &[String]) -> String {
    words.join("\u{1f}")
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CachedSpotIndex {
    version: u32,
    corpus_key: String,
    words: Vec<Word>,
    starts: Vec<usize>,
    unigrams: HashMap<String, Vec<usize>>,
    trigrams: HashMap<String, Vec<usize>>,
    bigrams: HashMap<String, Vec<usize>>,
}
impl SpotIndex {
    pub fn new(corpus: Arc<CorpusIndex>) -> Self {
        let mut words = Vec::new();
        let mut starts = Vec::new();
        for (i, v) in corpus.verses.iter().enumerate() {
            starts.push(words.len());
            for (local, w) in v.words.iter().enumerate() {
                words.push(Word {
                    verse: i,
                    local,
                    key: key(w),
                });
            }
        }
        let mut this = Self {
            corpus,
            words,
            starts,
            unigrams: HashMap::new(),
            trigrams: HashMap::new(),
            bigrams: HashMap::new(),
        };
        for n in [1, 2, 3] {
            for i in 0..this.words.len().saturating_sub(n - 1) {
                let first = &this.corpus.verses[this.words[i].verse];
                let last = &this.corpus.verses[this.words[i + n - 1].verse];
                if first.surah != last.surah {
                    continue;
                }
                let s = this.words[i..i + n]
                    .iter()
                    .map(|w| w.key.clone())
                    .collect::<Vec<_>>();
                let map = if n == 1 {
                    &mut this.unigrams
                } else if n == 3 {
                    &mut this.trigrams
                } else {
                    &mut this.bigrams
                };
                map.entry(shingle(&s)).or_default().push(i);
            }
        }
        this
    }
    pub fn cache_bytes(&self) -> Result<Vec<u8>> {
        #[derive(Serialize)]
        struct View<'a> {
            version: u32,
            corpus_key: &'a str,
            words: &'a [Word],
            starts: &'a [usize],
            unigrams: &'a HashMap<String, Vec<usize>>,
            trigrams: &'a HashMap<String, Vec<usize>>,
            bigrams: &'a HashMap<String, Vec<usize>>,
        }
        serde_json::to_vec(&View {
            version: 1,
            corpus_key: &self.corpus.cache_key,
            words: &self.words,
            starts: &self.starts,
            unigrams: &self.unigrams,
            trigrams: &self.trigrams,
            bigrams: &self.bigrams,
        })
        .map_err(|e| Error::Corpus(e.to_string()))
    }
    pub fn from_cache(corpus: Arc<CorpusIndex>, bytes: &[u8]) -> Result<Self> {
        if bytes.len() > 64 * 1024 * 1024 {
            return Err(Error::Corpus("spot cache exceeds limit".into()));
        }
        let c: CachedSpotIndex =
            serde_json::from_slice(bytes).map_err(|e| Error::Corpus(e.to_string()))?;
        if c.version != 1
            || c.corpus_key != corpus.cache_key
            || c.starts.len() != corpus.verses.len()
        {
            return Err(Error::Corpus("incompatible spot cache".into()));
        }
        let mut offset = 0;
        for (vi, v) in corpus.verses.iter().enumerate() {
            if c.starts[vi] != offset {
                return Err(Error::Corpus("invalid spot cache offsets".into()));
            }
            for (local, w) in v.words.iter().enumerate() {
                let item = c
                    .words
                    .get(offset)
                    .ok_or_else(|| Error::Corpus("incomplete spot cache".into()))?;
                if item.verse != vi || item.local != local || item.key != key(w) {
                    return Err(Error::Corpus("spot cache text mismatch".into()));
                }
                offset += 1;
            }
        }
        if offset != c.words.len() {
            return Err(Error::Corpus("invalid spot cache length".into()));
        }
        let result = Self {
            corpus,
            words: c.words,
            starts: c.starts,
            unigrams: c.unigrams,
            trigrams: c.trigrams,
            bigrams: c.bigrams,
        };
        for (n, map) in [
            (1, &result.unigrams),
            (2, &result.bigrams),
            (3, &result.trigrams),
        ] {
            let expected = (0..result.words.len().saturating_sub(n - 1))
                .filter(|i| result.same_surah(*i, *i + n - 1))
                .count();
            if map.values().map(Vec::len).sum::<usize>() != expected {
                return Err(Error::Corpus("incomplete spot cache postings".into()));
            }
            for (gram, postings) in map {
                if postings.windows(2).any(|p| p[0] >= p[1]) {
                    return Err(Error::Corpus("duplicate spot postings".into()));
                }
                for &i in postings {
                    if i.checked_add(n).is_none_or(|end| end > result.words.len())
                        || !result.same_surah(i, i + n - 1)
                    {
                        return Err(Error::Corpus("invalid spot posting".into()));
                    }
                    let keys = result.words[i..i + n]
                        .iter()
                        .map(|w| w.key.clone())
                        .collect::<Vec<_>>();
                    if shingle(&keys) != *gram {
                        return Err(Error::Corpus("spot shingle mismatch".into()));
                    }
                }
            }
        }
        Ok(result)
    }
    fn same_surah(&self, a: usize, b: usize) -> bool {
        self.corpus.verses[self.words[a].verse].surah
            == self.corpus.verses[self.words[b].verse].surah
    }
    fn equivalent(&self, doc: usize, query: &str) -> bool {
        self.words[doc].key == query || text::words_match(&self.words[doc].key, query)
    }
    fn hits(&self, query: &[String], limit: usize) -> Vec<Hit> {
        if query.is_empty() {
            return vec![];
        }
        let mut anchors: BTreeMap<(usize, usize), (BTreeSet<String>, BTreeSet<String>)> =
            BTreeMap::new();
        for n in [3, 2, 1] {
            if query.len() < n {
                continue;
            }
            for qi in 0..=query.len() - n {
                if n == 1
                    && query.len() > 1
                    && !self
                        .corpus
                        .verses
                        .iter()
                        .any(|v| v.words.len() == 1 && key(&v.words[0]) == query[qi])
                {
                    continue;
                }
                let gram = shingle(&query[qi..qi + n]);
                let map = if n == 1 {
                    &self.unigrams
                } else if n == 3 {
                    &self.trigrams
                } else {
                    &self.bigrams
                };
                if let Some(postings) = map.get(&gram) {
                    for &di in postings {
                        if anchors.len() >= 20_000 {
                            break;
                        }
                        let mut ds = di;
                        let mut qs = qi;
                        let mut de = di + n;
                        let mut qe = qi + n;
                        while ds > 0
                            && qs > 0
                            && self.same_surah(ds - 1, di)
                            && self.equivalent(ds - 1, &query[qs - 1])
                        {
                            ds -= 1;
                            qs -= 1;
                        }
                        while de < self.words.len()
                            && qe < query.len()
                            && self.same_surah(di, de)
                            && self.equivalent(de, &query[qe])
                        {
                            de += 1;
                            qe += 1;
                        }
                        let entry = anchors.entry((ds, qs)).or_default();
                        if n == 3 {
                            entry.0.insert(gram.clone());
                        } else if n == 2 {
                            entry.1.insert(gram.clone());
                        }
                    }
                }
            }
        }
        // Complete short ayahs are the explicit high-margin exception. Fuzzy
        // boundary matching admits the existing ASR spelling عم / عما; it never
        // modifies source text or substitutes words in the acoustic scorer.
        for (vi, v) in self
            .corpus
            .verses
            .iter()
            .enumerate()
            .filter(|(_, v)| (1..=4).contains(&v.words.len()))
        {
            let n = v.words.len();
            if n > query.len() {
                continue;
            }
            let di = self.starts[vi];
            for qi in 0..=query.len() - n {
                if (0..n).all(|w| {
                    if n == 1 {
                        self.words[di + w].key == query[qi + w]
                    } else {
                        self.equivalent(di + w, &query[qi + w])
                    }
                }) {
                    anchors.entry((di, qi)).or_default();
                }
            }
        }
        let mut hits = Vec::new();
        for ((ds, qs), (tri, bi)) in anchors {
            let mut de = ds;
            let mut qe = qs;
            while de < self.words.len()
                && qe < query.len()
                && self.same_surah(ds, de)
                && self.equivalent(de, &query[qe])
            {
                de += 1;
                qe += 1;
            }
            if de == ds {
                continue;
            }
            let v = &self.corpus.verses[self.words[ds].verse];
            let short = self.words[ds].local == 0
                && de == self.starts[self.words[ds].verse] + v.words.len()
                && v.words.len() <= 4;
            if tri.len() < 2 && bi.len() < 3 && !short && query.len() > 3 && de - ds != 1 {
                continue;
            }
            hits.push(Hit {
                span: ds..de,
                query: qs..qe,
                strength: tri.len() * 3 + bi.len() * 2,
            });
        }
        hits.sort_by_key(|h| {
            (
                std::cmp::Reverse(h.span.len()),
                std::cmp::Reverse(h.strength),
                std::cmp::Reverse(
                    self.words[h.span.start].local == 0
                        && self.words[h.span.end - 1].local + 1
                            == self.corpus.verses[self.words[h.span.end - 1].verse]
                                .words
                                .len(),
                ),
                h.span.start,
                h.query.start,
            )
        });
        let mut result: Vec<Hit> = vec![];
        for h in hits {
            if result.iter().any(|p| {
                p.span.start <= h.span.start
                    && p.span.end >= h.span.end
                    && p.query.start <= h.query.start
                    && p.query.end >= h.query.end
            }) {
                continue;
            }
            result.push(h);
            if result.len() == limit {
                break;
            }
        }
        result
    }
    fn candidate(&self, span: Range<usize>, confidence: f64) -> QuoteCandidate {
        let first = &self.words[span.start];
        let last = &self.words[span.end - 1];
        let a = &self.corpus.verses[first.verse];
        let b = &self.corpus.verses[last.verse];
        let mut texts = Vec::new();
        for vi in first.verse..=last.verse {
            let v = &self.corpus.verses[vi];
            let from = if vi == first.verse { first.local } else { 0 };
            let to = if vi == last.verse {
                last.local + 1
            } else {
                v.words.len()
            };
            texts.push(verbatim_words(&v.arabic, from..to));
        }
        let name = &self.corpus.surahs[a.surah as usize - 1].name_en;
        let reference = if a.ayah == b.ayah {
            format!("{name} {}:{}", a.surah, a.ayah)
        } else {
            format!("{name} {}:{}–{}", a.surah, a.ayah, b.ayah)
        };
        QuoteCandidate {
            surah: a.surah,
            ayah_from: a.ayah,
            ayah_to: b.ayah,
            word_from: first.local,
            word_to: last.local + 1,
            confidence,
            text_uthmani: texts.join("\n"),
            reference,
        }
    }
    fn tokens(&self, span: Range<usize>) -> Vec<Vec<u32>> {
        let first = &self.words[span.start];
        let last = &self.words[span.end - 1];
        let mut sequences = vec![Vec::new()];
        for vi in first.verse..=last.verse {
            let v = &self.corpus.verses[vi];
            let from = if vi == first.verse { first.local } else { 0 };
            let to = if vi == last.verse {
                last.local + 1
            } else {
                v.words.len()
            };
            let (tokens, ends) = v.tokens_for(from..to);
            let alt = text::alternate(v.surah, v.ayah, from, to, &tokens, &ends);
            let old = sequences.clone();
            for s in &mut sequences {
                s.extend(&tokens);
            }
            if let Some((alt, _)) = alt {
                for mut s in old {
                    s.extend(&alt);
                    sequences.push(s);
                }
            }
        }
        sequences
    }
    pub fn match_text(&self, segment: &str, cfg: &SpotConfig) -> Result<TextMatch> {
        cfg.validate()?;
        if segment.len() > 32_768 {
            return Err(Error::Invalid("text segment exceeds 32768 bytes".into()));
        }
        let query: Vec<_> = text::semantic_words(segment)
            .iter()
            .map(|s| key(s))
            .collect();
        if query.len() > 512 {
            return Err(Error::Invalid("text segment exceeds 512 words".into()));
        }
        let hits = self.hits(&query, cfg.max_candidates);
        let ambiguous = hits.len() > 1;
        let candidates = hits
            .iter()
            .map(|h| {
                self.candidate(
                    h.span.clone(),
                    if ambiguous {
                        0.5
                    } else {
                        0.5 * (h.query.len() as f64 / query.len().max(1) as f64)
                    },
                )
            })
            .collect();
        Ok(TextMatch {
            verified: false,
            ambiguous,
            candidates,
        })
    }
}
/// Select original byte ranges, retaining internal whitespace/marks unchanged.
fn verbatim_words(source: &str, range: Range<usize>) -> String {
    let mut words = Vec::new();
    let mut begin = None;
    for (i, c) in source
        .char_indices()
        .chain(std::iter::once((source.len(), ' ')))
    {
        if c.is_whitespace() {
            if let Some(start) = begin.take() {
                if !text::semantic_words(&source[start..i]).is_empty() {
                    words.push(start..i);
                }
            }
        } else if begin.is_none() {
            begin = Some(i);
        }
    }
    if range.start == 0 && range.end == words.len() {
        return source.to_owned();
    }
    source[words[range.start].start..words[range.end - 1].end].to_owned()
}
#[derive(Clone)]
struct Scored {
    hit: Hit,
    margin: f64,
    score: f64,
    eligible: bool,
    start: f64,
    end: f64,
}
#[derive(Clone)]
struct Open {
    quote: QuoteDetected,
    span: Range<usize>,
}
fn temporal_overlap(a: &QuoteDetected, b: &QuoteDetected) -> bool {
    a.start_seconds <= b.end_seconds + 0.4 && b.start_seconds <= a.end_seconds + 0.4
}
fn quote_candidates(q: &QuoteDetected) -> Vec<QuoteCandidate> {
    if !q.candidates.is_empty() {
        return q.candidates.clone();
    }
    if let (
        Some(surah),
        Some(ayah_from),
        Some(ayah_to),
        Some(word_from),
        Some(word_to),
        Some(text_uthmani),
        Some(reference),
    ) = (
        q.surah,
        q.ayah_from,
        q.ayah_to,
        q.word_from,
        q.word_to,
        q.text_uthmani.as_ref(),
        q.reference.as_ref(),
    ) {
        vec![QuoteCandidate {
            surah,
            ayah_from,
            ayah_to,
            word_from,
            word_to,
            text_uthmani: text_uthmani.clone(),
            reference: reference.clone(),
            confidence: q.confidence.min(0.5),
        }]
    } else {
        vec![]
    }
}
pub struct Spotter<M: AcousticModel> {
    model: M,
    pub index: Arc<SpotIndex>,
    cfg: SpotConfig,
    pieces: Vec<String>,
    pcm: VecDeque<f32>,
    total: u64,
    next_tick: u64,
    voice_end: u64,
    open: Option<Open>,
    quotes: Vec<QuoteDetected>,
    closed_spans: Vec<(Range<usize>, f64, f64)>,
    pending: Vec<Event>,
    started: bool,
    ended: bool,
}
impl<M: AcousticModel> Spotter<M> {
    pub fn new(model: M, corpus: Arc<CorpusIndex>, cfg: SpotConfig) -> Result<Self> {
        Self::with_index(model, Arc::new(SpotIndex::new(corpus)), cfg)
    }
    pub fn with_index(model: M, index: Arc<SpotIndex>, cfg: SpotConfig) -> Result<Self> {
        cfg.validate()?;
        let vocab: HashMap<String, String> =
            serde_json::from_str(include_str!("../../../model/vocab.json"))
                .map_err(|e| Error::Corpus(e.to_string()))?;
        let mut pieces = vec![String::new(); 1025];
        for (id, piece) in vocab {
            let id: usize = id
                .parse()
                .map_err(|_| Error::Corpus("invalid vocabulary id".into()))?;
            if id >= 1025 {
                return Err(Error::Corpus("invalid vocabulary shape".into()));
            }
            pieces[id] = piece;
        }
        Ok(Self {
            model,
            index,
            cfg,
            pieces,
            pcm: VecDeque::new(),
            total: 0,
            next_tick: RATE as u64,
            voice_end: 0,
            open: None,
            quotes: vec![],
            closed_spans: vec![],
            pending: vec![],
            started: false,
            ended: false,
        })
    }
    pub fn reset(&mut self) {
        self.pcm.clear();
        self.total = 0;
        self.next_tick = RATE as u64;
        self.voice_end = 0;
        self.open = None;
        self.quotes.clear();
        self.closed_spans.clear();
        self.pending.clear();
        self.started = false;
        self.ended = false;
    }
    pub fn feed(&mut self, pcm: &[f32]) -> Result<Vec<Event>> {
        if self.ended {
            return Err(Error::Invalid(
                "spotter ended; call reset before feeding".into(),
            ));
        }
        if pcm.len() > RATE * 60 || pcm.iter().any(|x| !x.is_finite()) {
            return Err(Error::Invalid(
                "feed requires at most 60 seconds of finite mono 16 kHz samples".into(),
            ));
        }
        if !self.started {
            self.started = true;
            self.pending.push(Event::State {
                state: State::Listening,
            });
        }
        let mut i = 0;
        while i < pcm.len() {
            let count = (self.next_tick.saturating_sub(self.total) as usize)
                .max(1)
                .min(pcm.len() - i);
            let chunk = &pcm[i..i + count];
            // RMS in short frames avoids treating low-level lecture room noise as a new syllable.
            for (offset, frame) in chunk.chunks(320).enumerate() {
                let rms = (frame.iter().map(|v| (*v as f64).powi(2)).sum::<f64>()
                    / frame.len() as f64)
                    .sqrt();
                if rms >= 0.008 {
                    self.voice_end = self.total + (offset * 320 + frame.len()) as u64;
                }
            }
            self.pcm.extend(chunk);
            self.total += count as u64;
            i += count;
            let max = (self.cfg.window_seconds * RATE as f64) as usize;
            if self.pcm.len() > max {
                self.pcm.drain(..self.pcm.len() - max);
            }
            if self.total >= self.next_tick {
                if self.pcm.len() >= RATE * 2 {
                    self.evaluate()?;
                }
                self.next_tick += RATE as u64;
            }
            if self.total.saturating_sub(self.voice_end) >= 19_200 {
                self.close();
            }
        }
        Ok(std::mem::take(&mut self.pending))
    }
    fn evaluate(&mut self) -> Result<()> {
        let input: Vec<_> = self.pcm.iter().copied().collect();
        if input.len() < RATE {
            return Ok(());
        }
        let output = self.model.infer(&input)?;
        let decoded = ctc::decode(
            &output.logits,
            output.time,
            output.vocab,
            &self.pieces,
            1024,
        )?;
        let emissions = word_emissions_for_spotting(&decoded.frames, &self.pieces);
        // The acoustic word frontier supplements energy-based silence, so quiet
        // but intelligible recitation is not closed solely by a fixed RMS floor.
        if let Some(last) = emissions.last() {
            let origin = self.total - self.pcm.len() as u64;
            let voiced =
                origin + (last.end.min(output.time) * input.len() / output.time.max(1)) as u64;
            self.voice_end = self.voice_end.max(voiced.min(self.total));
        }

        let query: Vec<_> = emissions.iter().map(|e| key(&e.text)).collect();
        let parents = self.index.hits(&query, self.cfg.max_candidates);
        let mut hits = Vec::new();
        for h in parents {
            // Rerank the retrieved span and its ayah-aligned prefixes/suffixes;
            // failure of a neighbouring ayah cannot erase a verified quote.
            for boundary in h.span.start + 1..h.span.end {
                if self.index.words[boundary].local == 0 {
                    let delta = boundary - h.span.start;
                    hits.push(Hit {
                        span: h.span.start..boundary,
                        query: h.query.start..h.query.start + delta,
                        strength: h.strength,
                    });
                    hits.push(Hit {
                        span: boundary..h.span.end,
                        query: h.query.start + delta..h.query.end,
                        strength: h.strength,
                    });
                }
            }
            hits.push(h);
        }
        let origin = (self.total - self.pcm.len() as u64) as f64 / RATE as f64;
        self.closed_spans.retain(|(_, _, end)| *end >= origin - 0.4);
        let mut scored = Vec::new();
        for mut h in hits {
            for (span, start, end) in &self.closed_spans {
                let hs = origin
                    + frame_seconds(emissions[h.query.start].start, input.len(), output.time);
                let he = origin
                    + frame_seconds(emissions[h.query.end - 1].end, input.len(), output.time);
                if hs <= *end + 0.4
                    && he >= *start - 0.4
                    && h.span.start >= span.start
                    && h.span.start < span.end
                {
                    let count = (span.end - h.span.start).min(h.span.len());
                    h.span.start += count;
                    h.query.start += count;
                    if h.span.is_empty() {
                        break;
                    }
                }
            }
            if h.span.is_empty() {
                continue;
            }
            if let Some(candidate) = self.score_hit(h, &emissions, &output, input.len(), origin)? {
                scored.push(candidate);
            }
        }
        if scored.is_empty()
            && self
                .open
                .as_ref()
                .is_some_and(|o| self.total as f64 / RATE as f64 - o.quote.end_seconds >= 1.2)
        {
            self.close();
        }
        // Earliest quote first; choose the longest prefix within the upstream
        // stable-score tolerance, never a weak long span over a strong short one.
        while scored.iter().any(|s| s.eligible) {
            scored.sort_by(|a, b| a.start.total_cmp(&b.start));
            let first = scored.iter().find(|s| s.eligible).unwrap().clone();
            let cluster: Vec<_> = scored
                .iter()
                .filter(|s| s.start < first.end && first.start < s.end)
                .collect();
            let peak = cluster
                .iter()
                .map(|s| s.score)
                .fold(f64::NEG_INFINITY, f64::max);
            let best = cluster
                .into_iter()
                .filter(|s| s.eligible && s.score >= peak - 0.12)
                .max_by(|a, b| {
                    a.hit
                        .span
                        .len()
                        .cmp(&b.hit.span.len())
                        .then_with(|| a.score.total_cmp(&b.score))
                })
                .unwrap()
                .clone();
            let mut alternatives = Vec::new();
            let mut remaining = Vec::new();
            for other in scored {
                let overlap = other.start < best.end && best.start < other.end;
                let same_occurrence = other.hit.span.start < best.hit.span.end
                    && best.hit.span.start < other.hit.span.end;
                if overlap
                    && !same_occurrence
                    && (best.score - other.score).abs() <= self.cfg.ambiguity_margin
                {
                    alternatives.push(other);
                } else if !overlap {
                    remaining.push(other);
                }
            }
            let best = if alternatives.is_empty() {
                self.extend_backwards(best, &emissions, &output, input.len(), origin)?
            } else {
                best
            };
            self.observe(best, &alternatives);
            scored = remaining;
        }
        if self.total.saturating_sub(self.voice_end) >= 19_200 {
            self.close();
        }
        Ok(())
    }
    fn score_hit(
        &self,
        h: Hit,
        emissions: &[ctc::WordEmission],
        output: &AcousticOutput,
        samples: usize,
        origin: f64,
    ) -> Result<Option<Scored>> {
        if h.span.is_empty() || h.query.is_empty() || h.query.end > emissions.len() {
            return Ok(None);
        }
        let first = &emissions[h.query.start];
        let last = &emissions[h.query.end - 1];
        let range = first.start.saturating_sub(2)..(last.end + 2).min(output.time);
        let time = range.len();
        let rows = &output.logits[range.start * output.vocab..range.end * output.vocab];
        let sequences = self.index.tokens(h.span.clone());
        let best = sequences
            .iter()
            .filter_map(|t| {
                ctc::score(rows, time, output.vocab, t, 1024)
                    .ok()
                    .map(|s| (s, t))
            })
            .max_by(|a, b| a.0.total_cmp(&b.0));
        let Some((score, tokens)) = best else {
            return Ok(None);
        };
        let mut negative = ctc::score(rows, time, output.vocab, &[], 1024)?;
        let first_word = &self.index.words[h.span.start];
        let verse = &self.index.corpus.verses[first_word.verse];
        let mut competitors = verse.confusers.clone();
        competitors.extend(
            first_word.verse.saturating_sub(2)
                ..(first_word.verse + 3).min(self.index.corpus.verses.len()),
        );
        if h.span.len() == 1 {
            competitors.extend(
                self.index
                    .corpus
                    .verses
                    .iter()
                    .enumerate()
                    .filter(|(_, v)| v.words.len() == 1)
                    .map(|(i, _)| i),
            );
        }
        competitors.sort_unstable();
        competitors.dedup();
        for vi in competitors {
            let t = &self.index.corpus.verses[vi].tokens;
            if sequences.contains(t) {
                continue;
            }
            if let Ok(s) = ctc::score(rows, time, output.vocab, t, 1024) {
                negative = negative.max(s);
            }
        }
        let margin = score - negative;
        if margin < self.cfg.min_margin {
            return Ok(None);
        }
        let aligned = ctc::forced_alignment(rows, time, output.vocab, tokens, 1024)?;
        let start = origin + frame_seconds(range.start + aligned[0].0, samples, output.time);
        let end = origin
            + frame_seconds(
                range.start + aligned.last().unwrap().1,
                samples,
                output.time,
            );
        let distinct = self.index.words[h.span.clone()]
            .iter()
            .map(|w| w.key.as_str())
            .collect::<BTreeSet<_>>()
            .len();
        let last_word = &self.index.words[h.span.end - 1];
        let short = first_word.verse == last_word.verse
            && first_word.local == 0
            && last_word.local + 1 == verse.words.len()
            && !verse.words.is_empty()
            && margin >= self.cfg.high_margin;
        if end - start < self.cfg.min_seconds {
            return Ok(None);
        }
        Ok(Some(Scored {
            hit: h,
            margin,
            score,
            eligible: distinct >= self.cfg.min_words || short,
            start,
            end,
        }))
    }
    fn extend_backwards(
        &self,
        seed: Scored,
        emissions: &[ctc::WordEmission],
        output: &AcousticOutput,
        samples: usize,
        origin: f64,
    ) -> Result<Scored> {
        let first = &self.index.words[seed.hit.span.start];
        let verse = &self.index.corpus.verses[first.verse];
        // Restore the beginning of a partially retrieved ayah, or inspect only
        // the immediately preceding ayah of the same surah. Never infer a
        // predecessor from its reference alone.
        let vi = if first.local > 0 {
            first.verse
        } else if verse.ayah > 1 && first.verse > 0 {
            first.verse - 1
        } else {
            return Ok(seed);
        };
        let previous = &self.index.corpus.verses[vi];
        if previous.surah != verse.surah {
            return Ok(seed);
        }
        let from = self.index.starts[vi];
        let to = from + previous.words.len();
        if to > seed.hit.span.end {
            return Ok(seed);
        }
        let missing = seed.hit.span.start - from;
        let Some(query_from) = seed.hit.query.start.checked_sub(missing) else {
            return Ok(seed);
        };
        let query_to = query_from + previous.words.len();
        if query_to > emissions.len() {
            return Ok(seed);
        }
        let prefix = Hit {
            span: from..to,
            query: query_from..query_to,
            strength: seed.hit.strength,
        };
        let Some(checked) = self.score_hit(prefix, emissions, output, samples, origin)? else {
            return Ok(seed);
        };
        // The new ayah must pass the existing duration, margin and complete-
        // short-ayah gates by itself; a strong seed cannot subsidize weak audio.
        if !checked.eligible
            || self.closed_spans.iter().any(|(span, start, end)| {
                span.start < to
                    && from < span.end
                    && checked.start <= *end + 0.4
                    && checked.end >= *start - 0.4
            })
        {
            return Ok(seed);
        }
        let joint = Hit {
            span: from..seed.hit.span.end,
            query: query_from..seed.hit.query.end,
            strength: seed.hit.strength,
        };
        let Some(extended) = self.score_hit(joint, emissions, output, samples, origin)? else {
            return Ok(seed);
        };
        if extended.eligible
            && extended.start <= checked.start + 0.25
            && extended.end >= seed.end - 0.25
        {
            Ok(Scored {
                margin: extended.margin.min(seed.margin).min(checked.margin),
                ..extended
            })
        } else {
            Ok(seed)
        }
    }
    fn observe(&mut self, best: Scored, others: &[Scored]) {
        let ambiguous = !others.is_empty();
        let confidence = if ambiguous {
            0.5
        } else {
            -(-best.margin.max(0.)).exp_m1()
        };
        let chosen = self.index.candidate(best.hit.span.clone(), confidence);
        let candidates = if ambiguous {
            std::iter::once(chosen.clone())
                .chain(
                    others
                        .iter()
                        .map(|s| self.index.candidate(s.hit.span.clone(), 0.5)),
                )
                .take(self.cfg.max_candidates)
                .collect()
        } else {
            vec![]
        };
        let quote = QuoteDetected {
            surah: (!ambiguous).then_some(chosen.surah),
            ayah_from: (!ambiguous).then_some(chosen.ayah_from),
            ayah_to: (!ambiguous).then_some(chosen.ayah_to),
            word_from: (!ambiguous).then_some(chosen.word_from),
            word_to: (!ambiguous).then_some(chosen.word_to),
            start_seconds: best.start,
            end_seconds: best.end,
            confidence,
            text_uthmani: (!ambiguous).then_some(chosen.text_uthmani),
            reference: (!ambiguous).then_some(chosen.reference),
            verified: !ambiguous,
            ambiguous,
            candidates,
        };
        if self.quotes.iter().any(|q| {
            q.surah == quote.surah
                && q.ayah_from == quote.ayah_from
                && q.ayah_to == quote.ayah_to
                && temporal_overlap(q, &quote)
        }) {
            return;
        }
        if let Some(open) = &mut self.open {
            let intersects = open.quote.start_seconds < quote.end_seconds
                && quote.start_seconds < open.quote.end_seconds;
            // Do not emit an earlier provisional winner when a later window
            // reveals ambiguity. Only stronger additional context can resolve it.
            if intersects
                && open.quote.ambiguous
                && !ambiguous
                && best.margin >= self.cfg.high_margin
                && best.hit.span.len() > open.span.len()
                && quote.start_seconds <= open.quote.start_seconds + 0.3
                && quote.end_seconds >= open.quote.end_seconds + 0.25
            {
                *open = Open {
                    quote,
                    span: best.hit.span,
                };
                return;
            }
            if intersects && (ambiguous || open.quote.ambiguous || open.quote.surah != quote.surah)
            {
                let mut options = quote_candidates(&open.quote);
                options.extend(quote_candidates(&quote));
                let mut seen = BTreeSet::new();
                options.retain(|c| {
                    seen.insert((c.surah, c.ayah_from, c.ayah_to, c.word_from, c.word_to))
                });
                options.truncate(self.cfg.max_candidates);
                open.quote = QuoteDetected {
                    surah: None,
                    ayah_from: None,
                    ayah_to: None,
                    word_from: None,
                    word_to: None,
                    start_seconds: open.quote.start_seconds.min(quote.start_seconds),
                    end_seconds: open.quote.end_seconds.max(quote.end_seconds),
                    confidence: 0.5,
                    text_uthmani: None,
                    reference: None,
                    verified: false,
                    ambiguous: true,
                    candidates: options,
                };
                return;
            }
            let compatible = !ambiguous
                && !open.quote.ambiguous
                && self.index.same_surah(open.span.start, best.hit.span.start)
                && best.hit.span.start <= open.span.end
                && open.span.start <= best.hit.span.end
                && (temporal_overlap(&open.quote, &quote)
                    || ((best.hit.span.start == open.span.end
                        || best.hit.span.end == open.span.start)
                        && quote.start_seconds <= open.quote.end_seconds + 1.2
                        && open.quote.start_seconds <= quote.end_seconds + 1.2));
            if compatible {
                open.span =
                    open.span.start.min(best.hit.span.start)..open.span.end.max(best.hit.span.end);
                let c = self
                    .index
                    .candidate(open.span.clone(), open.quote.confidence.max(confidence));
                open.quote.ayah_from = Some(c.ayah_from);
                open.quote.ayah_to = Some(c.ayah_to);
                open.quote.word_from = Some(c.word_from);
                open.quote.word_to = Some(c.word_to);
                open.quote.text_uthmani = Some(c.text_uthmani);
                open.quote.reference = Some(c.reference);
                open.quote.start_seconds = open.quote.start_seconds.min(quote.start_seconds);
                open.quote.end_seconds = open.quote.end_seconds.max(quote.end_seconds);
                open.quote.confidence = c.confidence;
                return;
            }
            if ambiguous && open.quote.ambiguous && temporal_overlap(&open.quote, &quote) {
                open.quote.end_seconds = open.quote.end_seconds.max(quote.end_seconds);
                return;
            }
            self.close();
        }
        self.open = Some(Open {
            quote,
            span: best.hit.span,
        });
    }
    fn close(&mut self) {
        if let Some(open) = self.open.take() {
            self.closed_spans.push((
                open.span.clone(),
                open.quote.start_seconds,
                open.quote.end_seconds,
            ));
            self.pending.push(Event::QuoteDetected {
                quote: open.quote.clone(),
            });
            self.quotes.push(open.quote);
        }
    }
    pub fn stop(&mut self) -> Result<Summary> {
        if !self.ended {
            self.pending.push(Event::State {
                state: State::Evaluating,
            });
            if !self.total.is_multiple_of(RATE as u64) && self.pcm.len() >= RATE {
                self.evaluate()?;
            }
            self.close();
            self.ended = true;
            self.pending.push(Event::State {
                state: State::Ended,
            });
        }
        Ok(Summary {
            quotes: self.quotes.clone(),
            duration: self.total as f64 / RATE as f64,
            events: std::mem::take(&mut self.pending),
            ..Default::default()
        })
    }
}
fn word_emissions_for_spotting(frames: &[u32], pieces: &[String]) -> Vec<ctc::WordEmission> {
    ctc::word_emissions(frames, pieces, 1024)
        .into_iter()
        .filter_map(|mut word| {
            let lexical = |id: &u32| {
                *id != 1024
                    && pieces.get(*id as usize).is_some_and(|p| {
                        p != "<unk>" && p != "<blank>" && !text::letters(p).is_empty()
                    })
            };
            let original = word.start;
            let range = &frames[word.start..word.end];
            let first = range.iter().position(lexical)?;
            let last = range.iter().rposition(lexical)?;
            word.start = original + first;
            word.end = original + last + 1;
            Some(word)
        })
        .collect()
}
pub fn frame_seconds(frame: usize, samples: usize, frames: usize) -> f64 {
    frame.min(frames) as f64 * samples as f64 / (frames.max(1) as f64 * RATE as f64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::AcousticOutput;
    #[derive(Deserialize)]
    struct Fixture {
        surah: u16,
        ayah_from: u16,
        ayah_to: u16,
        frame_samples: usize,
        leading_frames: usize,
        token_frames: usize,
        blank_frames: usize,
        seconds: usize,
    }
    struct Timeline {
        labels: Vec<u32>,
        calls: Arc<std::sync::atomic::AtomicUsize>,
    }
    impl AcousticModel for Timeline {
        fn infer(&mut self, pcm: &[f32]) -> Result<AcousticOutput> {
            self.calls
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let first = pcm[0] as f64;
            let base = if first >= 0.05 { 0.1 } else { 0. };
            let origin =
                (((first - base) * 1e8 / RATE as f64).round() * RATE as f64).max(0.) as usize;
            let time = pcm.len().div_ceil(1280);
            let mut logits = vec![-12.; time * 1025];
            for t in 0..time {
                let id = self
                    .labels
                    .get((origin + t * 1280) / 1280)
                    .copied()
                    .unwrap_or(1024);
                logits[t * 1025 + id as usize] = -0.001;
            }
            for row in logits.chunks_mut(1025) {
                let z = row.iter().map(|x| (*x as f64).exp()).sum::<f64>().ln() as f32;
                for x in row {
                    *x -= z;
                }
            }
            Ok(AcousticOutput {
                logits,
                time,
                vocab: 1025,
            })
        }
    }
    #[test]
    fn shingle_index_known_trigram_and_cross_ayah_span() {
        let index = SpotIndex::new(crate::corpus::test_index());
        let m = index
            .match_text("عَمَّ يَتَسَاءَلُونَ عَنِ النَّبَإِ الْعَظِيمِ", &SpotConfig::default())
            .unwrap();
        let c = m.candidates.iter().find(|c| c.surah == 78).unwrap();
        assert_eq!((c.ayah_from, c.ayah_to), (1, 2));
        assert!(!m.verified);
    }
    #[test]
    fn disambiguation_common_phrase_returns_candidates_never_verdict() {
        let index = SpotIndex::new(crate::corpus::test_index());
        for phrase in [
            "الذين آمنوا",
            "بسم الله الرحمن الرحيم",
            "فبأي آلاء ربكما تكذبان",
        ] {
            let m = index.match_text(phrase, &SpotConfig::default()).unwrap();
            assert!(!m.verified);
            assert!(m.ambiguous, "{phrase}");
            assert!(m.candidates.len() > 1);
            assert!(m.candidates.iter().all(|c| c.confidence <= 0.5));
        }
        assert!(index
            .match_text(
                "The teacher explains photosynthesis today",
                &SpotConfig::default()
            )
            .unwrap()
            .candidates
            .is_empty());
    }
    #[test]
    fn display_spans_are_verbatim_tanzil_not_normalized() {
        let corpus = crate::corpus::test_index();
        let index = SpotIndex::new(corpus.clone());
        let start = index.starts[corpus.verse_index(78, 1).unwrap()];
        let c = index.candidate(start..start + 5, 0.8);
        assert_eq!(
            c.text_uthmani,
            format!(
                "{}\n{}",
                corpus.verse(78, 1).unwrap().arabic,
                corpus.verse(78, 2).unwrap().arabic
            )
        );
        let v = corpus.verse(97, 1).unwrap();
        let start = index.starts[corpus.verse_index(97, 1).unwrap()];
        let c = index.candidate(start + 1..start + 3, 0.8);
        assert!(v.arabic.contains(&c.text_uthmani));
        assert_ne!(c.text_uthmani, text::normalize_arabic(&c.text_uthmani));
    }
    #[test]
    fn frame_span_maps_to_absolute_audio_time() {
        assert!((frame_seconds(25, 128000, 100) - 2.).abs() < 1e-9);
        assert_eq!(frame_seconds(101, 128000, 100), 8.);
    }
    #[test]
    fn synthetic_two_ayah_quote_between_noise_emits_once_with_times() {
        let f: Fixture =
            serde_json::from_str(include_str!("../../../tests/fixtures/spot-two-ayah.json"))
                .unwrap();
        let corpus = crate::corpus::test_index();
        let mut labels = vec![1024; f.leading_frames];
        for ayah in f.ayah_from..=f.ayah_to {
            for id in &corpus.verse(f.surah, ayah).unwrap().tokens {
                labels.extend(std::iter::repeat_n(*id, f.token_frames));
                labels.extend(std::iter::repeat_n(1024, f.blank_frames));
            }
        }
        let end = labels.len() * f.frame_samples;
        labels.resize(f.seconds * RATE / f.frame_samples + 1, 1024);
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut spot = Spotter::new(
            Timeline {
                labels,
                calls: calls.clone(),
            },
            corpus,
            SpotConfig::default(),
        )
        .unwrap();
        let pcm: Vec<_> = (0..f.seconds * RATE)
            .map(|n| {
                n as f32 / 1e8
                    + if n >= f.leading_frames * f.frame_samples && n < end {
                        0.1
                    } else {
                        0.
                    }
            })
            .collect();
        let mut events = vec![];
        for chunk in pcm.chunks(4800) {
            events.extend(spot.feed(chunk).unwrap());
        }
        let summary = spot.stop().unwrap();
        events.extend(summary.events);
        let quotes: Vec<_> = events
            .iter()
            .filter_map(|e| {
                if let Event::QuoteDetected { quote } = e {
                    Some(quote)
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(quotes.len(), 1, "{quotes:?}");
        let q = quotes[0];
        assert_eq!(
            (q.surah, q.ayah_from, q.ayah_to),
            (Some(78), Some(1), Some(2))
        );
        assert!(q.verified && !q.ambiguous);
        assert!((q.start_seconds - 2.).abs() < 0.3, "{}", q.start_seconds);
        assert!(
            (q.end_seconds - end as f64 / RATE as f64).abs() < 0.3,
            "{}",
            q.end_seconds
        );
        assert_eq!(summary.quotes.len(), 1);
        assert_eq!(calls.load(std::sync::atomic::Ordering::Relaxed), 11);
    }
    #[test]
    fn invalid_spot_config_cannot_lower_tracking_margin() {
        let cfg = SpotConfig {
            min_margin: 0.,
            ..Default::default()
        };
        assert!(cfg.validate().is_err());
        let cfg = SpotConfig {
            window_seconds: f64::NAN,
            ..Default::default()
        };
        assert!(cfg.validate().is_err());
    }
    fn synthesize_single(
        surah: u16,
        ayah: u16,
        alternate: bool,
        hold: usize,
    ) -> Vec<QuoteDetected> {
        let corpus = crate::corpus::test_index();
        let v = corpus.verse(surah, ayah).unwrap();
        let tokens = if alternate {
            text::alternate(surah, ayah, 0, v.words.len(), &v.tokens, &v.word_token_ends)
                .unwrap()
                .0
        } else {
            v.tokens.clone()
        };
        let mut labels = vec![1024; 25];
        for id in tokens {
            labels.extend(std::iter::repeat_n(id, hold));
            labels.push(1024);
        }
        let end = labels.len() * 1280;
        labels.resize(151, 1024);
        let model = Timeline {
            labels,
            calls: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
        };
        let mut spot = Spotter::new(model, corpus, SpotConfig::default()).unwrap();
        let pcm: Vec<_> = (0..12 * RATE)
            .map(|n| {
                n as f32 / 1e8
                    + if (25 * 1280..end).contains(&n) {
                        0.1
                    } else {
                        0.
                    }
            })
            .collect();
        for chunk in pcm.chunks(4800) {
            spot.feed(chunk).unwrap();
        }
        spot.stop().unwrap().quotes
    }
    #[test]
    fn acoustic_repeated_ayah_is_ambiguous_without_a_selected_citation() {
        let q = synthesize_single(55, 13, false, 5);
        assert_eq!(q.len(), 1, "{q:?}");
        let q = &q[0];
        assert!(q.ambiguous && !q.verified);
        assert!(q.surah.is_none() && q.text_uthmani.is_none() && q.reference.is_none());
        assert!(q.confidence <= 0.5);
        assert!(q.candidates.len() >= 2);
    }
    #[test]
    fn pronunciation_variant_is_verified_but_display_is_untouched() {
        let q = synthesize_single(112, 1, true, 5);
        assert_eq!(q.len(), 1, "{q:?}");
        let q = &q[0];
        assert!(q.verified);
        assert_eq!(q.surah, Some(112));
        assert_eq!(
            q.text_uthmani.as_ref().unwrap(),
            &crate::corpus::test_index().verse(112, 1).unwrap().arabic
        );
    }
    #[test]
    fn complete_ayah_below_minimum_audio_duration_is_not_a_quote() {
        assert!(synthesize_single(112, 1, true, 1).is_empty());
    }
    #[test]
    fn runtime_spot_cache_roundtrip_and_corruption_rejection() {
        let corpus = crate::corpus::test_index();
        let index = SpotIndex::new(corpus.clone());
        let bytes = index.cache_bytes().unwrap();
        let loaded = SpotIndex::from_cache(corpus.clone(), &bytes).unwrap();
        assert_eq!(
            index
                .match_text("عم يتساءلون عن النبإ العظيم", &SpotConfig::default())
                .unwrap(),
            loaded
                .match_text("عم يتساءلون عن النبإ العظيم", &SpotConfig::default())
                .unwrap()
        );
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["words"][0]["key"] = serde_json::json!("changed");
        assert!(SpotIndex::from_cache(corpus, &serde_json::to_vec(&value).unwrap()).is_err());
    }
    #[test]
    fn complete_single_word_ayah_uses_high_margin_exception() {
        let q = synthesize_single(55, 64, false, 5);
        assert_eq!(q.len(), 1, "{q:?}");
        assert_eq!(q[0].surah, Some(55));
        assert_eq!(q[0].ayah_from, Some(64));
        assert!(q[0].verified);
    }
    #[test]
    fn shared_single_word_ayah_never_becomes_a_unique_pick() {
        let q = synthesize_single(55, 1, false, 24);
        assert_eq!(q.len(), 1, "{q:?}");
        assert!(!q[0].verified && q[0].ambiguous);
        assert!(q[0].surah.is_none());
        assert!(q[0].candidates.len() >= 2);
    }
}

#[cfg(test)]
mod recall_tests;
