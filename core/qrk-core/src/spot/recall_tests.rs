use super::*;
use crate::AcousticOutput;
#[derive(Deserialize)]
struct RecallFixture {
    frame_samples: usize,
    backward_seed: BackwardFixture,
    short_ayah: ShortFixture,
}
#[derive(Deserialize)]
struct BackwardFixture {
    surah: u16,
    ayah_from: u16,
    ayah_to: u16,
    origin_seconds: usize,
    window_seconds: usize,
    leading_frames: usize,
    token_frames: usize,
    blank_frames: usize,
    gap_frames: usize,
    misdecoded_first_piece: String,
    misdecoded_continuation_piece: String,
}
#[derive(Deserialize)]
struct ShortFixture {
    surah: u16,
    ayah: u16,
    origin_seconds: usize,
    leading_frames: usize,
    token_frames: usize,
    blank_frames: usize,
    windows_seconds: Vec<usize>,
    trailing_nonlexical_piece: String,
    blank_penalty: f32,
}
struct WindowOutput(Option<AcousticOutput>);
impl AcousticModel for WindowOutput {
    fn infer(&mut self, _: &[f32]) -> Result<AcousticOutput> {
        Ok(self.0.take().expect("one forward for this fixture"))
    }
}
fn recall_fixture() -> RecallFixture {
    serde_json::from_str(include_str!(
        "../../../../tests/fixtures/spot-recall-031.json"
    ))
    .unwrap()
}
fn piece_id(piece: &str) -> u32 {
    let vocab: HashMap<String, String> =
        serde_json::from_str(include_str!("../../../../model/vocab.json")).unwrap();
    vocab
        .into_iter()
        .find(|(_, p)| p == piece)
        .unwrap()
        .0
        .parse()
        .unwrap()
}
fn normalize_fixture_rows(logits: &mut [f32]) {
    for row in logits.chunks_mut(1025) {
        let z = row.iter().map(|x| (*x as f64).exp()).sum::<f64>().ln() as f32;
        for x in row {
            *x -= z;
        }
    }
}
fn evaluate_window(
    corpus: Arc<CorpusIndex>,
    mut logits: Vec<f32>,
    origin: usize,
    seconds: usize,
    frame_samples: usize,
) -> Vec<QuoteDetected> {
    normalize_fixture_rows(&mut logits);
    let time = logits.len() / 1025;
    let mut spot = Spotter::new(
        WindowOutput(Some(AcousticOutput {
            logits,
            time,
            vocab: 1025,
        })),
        corpus,
        SpotConfig {
            window_seconds: seconds as f64,
            ..Default::default()
        },
    )
    .unwrap();
    spot.pcm = vec![0.1; time * frame_samples].into();
    spot.total = ((origin + seconds) * RATE) as u64;
    spot.voice_end = spot.total;
    spot.evaluate().unwrap();
    spot.close();
    spot.quotes
}
fn backward_logits(
    corpus: &CorpusIndex,
    f: &BackwardFixture,
    frame_samples: usize,
    audible_prefix: bool,
) -> Vec<f32> {
    let time = f.window_seconds * RATE / frame_samples;
    let mut logits = vec![-12.; time * 1025];
    for row in logits.chunks_mut(1025) {
        row[1024] = -0.001;
    }
    let mut at = f.leading_frames;
    for ayah in f.ayah_from..=f.ayah_to {
        let v = corpus.verse(f.surah, ayah).unwrap();
        for (token_index, &id) in v.tokens.iter().enumerate() {
            for _ in 0..f.token_frames {
                assert!(at < time, "fixture must fit window");
                let row = &mut logits[at * 1025..(at + 1) * 1025];
                row.fill(-12.);
                row[id as usize] = -0.001;
                if ayah == f.ayah_from {
                    let starts_word = token_index == 0 || v.word_token_ends.contains(&token_index);
                    let wrong = if starts_word {
                        &f.misdecoded_first_piece
                    } else {
                        &f.misdecoded_continuation_piece
                    };
                    row[piece_id(wrong) as usize] = 0.05;
                    row[1024] = -2.;
                    if !audible_prefix {
                        row[id as usize] = -12.;
                    }
                }
                at += 1;
            }
            at += f.blank_frames;
        }
        if ayah != f.ayah_to {
            at += f.gap_frames;
        }
    }
    logits
}
fn fully_covers(q: &QuoteDetected, corpus: &CorpusIndex, surah: u16, ayah: u16) -> bool {
    q.verified
        && q.surah == Some(surah)
        && q.ayah_from.is_some_and(|a| a <= ayah)
        && q.ayah_to.is_some_and(|a| a >= ayah)
        && (q.ayah_from != Some(ayah) || q.word_from == Some(0))
        && (q.ayah_to != Some(ayah)
            || q.word_to == Some(corpus.verse(surah, ayah).unwrap().words.len()))
}
fn receipt(
    case: &str,
    window: usize,
    matched: usize,
    expected: usize,
    false_positives: usize,
    quotes: &[QuoteDetected],
) {
    println!(
        "RECALL_CASE {}",
        serde_json::json!({"case":case,"window_seconds":window,"matched":matched,"expected":expected,"false_positives":false_positives,"quotes":quotes})
    );
}
#[test]
fn verified_seed_recovers_immediately_preceding_ayah_and_merges_span() {
    let fixture = recall_fixture();
    let f = fixture.backward_seed;
    let corpus = crate::corpus::test_index();
    let logits = backward_logits(&corpus, &f, fixture.frame_samples, true);
    let quotes = evaluate_window(
        corpus.clone(),
        logits,
        f.origin_seconds,
        f.window_seconds,
        fixture.frame_samples,
    );
    let matched = (f.ayah_from..=f.ayah_to)
        .filter(|a| quotes.iter().any(|q| fully_covers(q, &corpus, f.surah, *a)))
        .count();
    receipt(
        "backward_seed",
        f.window_seconds,
        matched,
        (f.ayah_to - f.ayah_from + 1) as usize,
        0,
        &quotes,
    );
    assert_eq!(quotes.len(), 1, "{quotes:?}");
    assert_eq!(
        (quotes[0].surah, quotes[0].ayah_from, quotes[0].ayah_to),
        (Some(f.surah), Some(f.ayah_from), Some(f.ayah_to))
    );
    assert!(quotes[0].verified && !quotes[0].ambiguous);
    assert_eq!(quotes[0].word_from, Some(0));
    let exact = format!(
        "{}\n{}",
        corpus.verse(f.surah, f.ayah_from).unwrap().arabic,
        corpus.verse(f.surah, f.ayah_to).unwrap().arabic
    );
    assert_eq!(quotes[0].text_uthmani.as_ref(), Some(&exact));
    assert!(
        (quotes[0].start_seconds - (f.origin_seconds as f64 + f.leading_frames as f64 * 0.08))
            .abs()
            < 0.25
    );
}
#[test]
fn short_ayah_scoring_ignores_nonlexical_tail_for_every_window_size() {
    let fixture = recall_fixture();
    let f = fixture.short_ayah;
    let corpus = crate::corpus::test_index();
    let mut passed = Vec::new();
    let mut timings = Vec::new();
    for seconds in f.windows_seconds {
        let time = seconds * RATE / fixture.frame_samples;
        let mut logits = vec![-12.; time * 1025];
        for row in logits.chunks_mut(1025) {
            row[1024] = -0.001;
        }
        let mut at = f.leading_frames;
        for &id in &corpus.verse(f.surah, f.ayah).unwrap().tokens {
            for _ in 0..f.token_frames {
                assert!(at < time, "fixture must fit window");
                let row = &mut logits[at * 1025..(at + 1) * 1025];
                row.fill(-12.);
                row[id as usize] = 0.;
                row[1024] = -f.blank_penalty;
                at += 1;
            }
            at += f.blank_frames;
        }
        let expected_end = f.origin_seconds as f64 + (at - f.blank_frames) as f64 * 0.08;
        for row in logits[at * 1025..].chunks_mut(1025) {
            row.fill(-12.);
            row[piece_id(&f.trailing_nonlexical_piece) as usize] = 0.;
            row[1024] = -0.5;
        }
        let quotes = evaluate_window(
            corpus.clone(),
            logits,
            f.origin_seconds,
            seconds,
            fixture.frame_samples,
        );
        let found = quotes.iter().any(|q| {
            q.verified
                && q.surah == Some(f.surah)
                && q.ayah_from == Some(f.ayah)
                && q.ayah_to == Some(f.ayah)
        });
        receipt(
            "short_ayah_tail",
            seconds,
            usize::from(found),
            1,
            0,
            &quotes,
        );
        passed.push(found);
        if let Some(q) = quotes.first() {
            assert!((q.end_seconds - expected_end).abs() < 0.25);
            timings.push((q.start_seconds, q.end_seconds, q.confidence));
        }
    }
    assert!(passed.iter().all(|v| *v), "window recall: {passed:?}");
    for pair in timings.windows(2) {
        assert!((pair[0].0 - pair[1].0).abs() < 1e-6);
        assert!((pair[0].1 - pair[1].1).abs() < 1e-6);
        assert!((pair[0].2 - pair[1].2).abs() < 1e-6);
    }
}

#[test]
fn strong_seed_does_not_subsidize_an_inaudible_preceding_ayah() {
    let fixture = recall_fixture();
    let f = fixture.backward_seed;
    let corpus = crate::corpus::test_index();
    let logits = backward_logits(&corpus, &f, fixture.frame_samples, false);
    let quotes = evaluate_window(
        corpus.clone(),
        logits,
        f.origin_seconds,
        f.window_seconds,
        fixture.frame_samples,
    );
    let fp = quotes
        .iter()
        .filter(|q| fully_covers(q, &corpus, f.surah, f.ayah_from))
        .count();
    let matched = usize::from(
        quotes
            .iter()
            .any(|q| fully_covers(q, &corpus, f.surah, f.ayah_to)),
    );
    receipt(
        "inaudible_prefix",
        f.window_seconds,
        matched,
        1,
        fp,
        &quotes,
    );
    assert_eq!(fp, 0, "{quotes:?}");
    assert_eq!(matched, 1, "{quotes:?}");
}
struct ReplayWindow {
    logits: Vec<f32>,
}
impl AcousticModel for ReplayWindow {
    fn infer(&mut self, pcm: &[f32]) -> Result<AcousticOutput> {
        let first = pcm[0] as f64;
        let origin = ((first - if first >= 0.05 { 0.1 } else { 0. }) * 1e8)
            .round()
            .max(0.) as usize;
        let time = pcm.len().div_ceil(1280);
        let mut logits = Vec::with_capacity(time * 1025);
        for t in 0..time {
            let at = ((origin + t * 1280) / 1280) * 1025;
            if at + 1025 <= self.logits.len() {
                logits.extend_from_slice(&self.logits[at..at + 1025]);
            } else {
                let mut row = vec![-12.; 1025];
                row[1024] = -0.001;
                logits.extend(row);
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
fn backward_recovery_streams_one_merged_quote_across_overlapping_windows() {
    let fixture = recall_fixture();
    let f = fixture.backward_seed;
    let corpus = crate::corpus::test_index();
    let mut local = backward_logits(&corpus, &f, fixture.frame_samples, true);
    normalize_fixture_rows(&mut local);
    let before = f.origin_seconds * RATE / fixture.frame_samples;
    let mut logits = vec![-12.; (before + local.len() / 1025 + 50) * 1025];
    for row in logits.chunks_mut(1025) {
        row[1024] = -0.001;
    }
    logits[before * 1025..before * 1025 + local.len()].copy_from_slice(&local);
    let samples = logits.len() / 1025 * fixture.frame_samples;
    let pcm: Vec<_> = (0..samples)
        .map(|n| {
            let row =
                &logits[(n / fixture.frame_samples) * 1025..(n / fixture.frame_samples + 1) * 1025];
            let voiced = row
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.total_cmp(b.1))
                .unwrap()
                .0
                != 1024;
            n as f32 / 1e8 + if voiced { 0.1 } else { 0. }
        })
        .collect();
    let mut spot = Spotter::new(
        ReplayWindow { logits },
        corpus.clone(),
        SpotConfig::default(),
    )
    .unwrap();
    let mut events = vec![];
    for chunk in pcm.chunks(4800) {
        events.extend(spot.feed(chunk).unwrap());
    }
    let summary = spot.stop().unwrap();
    events.extend(summary.events);
    let quotes: Vec<_> = events
        .into_iter()
        .filter_map(|e| {
            if let Event::QuoteDetected { quote } = e {
                Some(quote)
            } else {
                None
            }
        })
        .collect();
    let matched = (f.ayah_from..=f.ayah_to)
        .filter(|a| quotes.iter().any(|q| fully_covers(q, &corpus, f.surah, *a)))
        .count();
    receipt("streaming_backward_seed", 8, matched, 2, 0, &quotes);
    assert_eq!(matched, 2, "{quotes:?}");
    assert_eq!(quotes.len(), 1, "{quotes:?}");
    assert_eq!(summary.quotes.len(), 1);
    assert_eq!(quotes[0].word_from, Some(0));
    assert_eq!(quotes[0].ayah_to, Some(f.ayah_to));
}

#[test]
fn verified_adjacent_ayahs_merge_only_inside_the_existing_silence_boundary() {
    let corpus = crate::corpus::test_index();
    // Acoustic acceptance is tested above; exercise the downstream publication
    // boundary with two independently verified candidates and no extra forward.
    for (surah, ayah, gap, expected) in [
        (78, 2, 0.8, 1),
        (78, 2, 1.3, 2),
        (78, 3, 0.8, 2),
        (79, 1, 0.8, 2),
    ] {
        let mut spot =
            Spotter::new(WindowOutput(None), corpus.clone(), SpotConfig::default()).unwrap();
        let make = |index: &SpotIndex, surah, ayah, start, end| {
            let vi = corpus.verse_index(surah, ayah).unwrap();
            let from = index.starts[vi];
            let to = from + corpus.verses[vi].words.len();
            Scored {
                hit: Hit {
                    span: from..to,
                    query: 0..to - from,
                    strength: 1,
                },
                margin: 0.5,
                score: -0.02,
                eligible: true,
                start,
                end,
            }
        };
        spot.observe(make(&spot.index, 78, 1, 0., 2.), &[]);
        spot.observe(make(&spot.index, surah, ayah, 2. + gap, 4. + gap), &[]);
        spot.total = 5 * RATE as u64;
        let summary = spot.stop().unwrap();
        if expected == 1 {
            receipt("adjacent_verified_quotes", 8, 2, 2, 0, &summary.quotes);
        }
        assert_eq!(
            summary.quotes.len(),
            expected,
            "surah={surah} ayah={ayah} gap={gap}: {:?}",
            summary.quotes
        );
        if expected == 1 {
            assert_eq!(
                summary.quotes[0].reference.as_deref(),
                Some("An-Naba 78:1–2")
            );
            assert_eq!(summary.quotes[0].start_seconds, 0.);
            assert_eq!(summary.quotes[0].end_seconds, 4. + gap);
        }
    }
}

#[test]
fn closed_basmala_stays_ambiguous_when_a_later_unique_quote_arrives() {
    let corpus = crate::corpus::test_index();
    let mut false_positives = Vec::new();
    for window in [8, 12] {
        let mut logits = vec![-12.; 275 * 1025];
        for row in logits.chunks_mut(1025) {
            row[1024] = -0.001;
        }
        let mut at = 25;
        for (surah, ayah, hold) in [(1, 1, 4), (78, 2, 6)] {
            for &id in &corpus.verse(surah, ayah).unwrap().tokens {
                for _ in 0..hold {
                    let row = &mut logits[at * 1025..(at + 1) * 1025];
                    row.fill(-12.);
                    row[id as usize] = -0.001;
                    at += 1;
                }
                at += 1;
            }
            at += 17;
        }
        normalize_fixture_rows(&mut logits);
        let pcm: Vec<_> = (0..275 * 1280)
            .map(|n| {
                let row = &logits[(n / 1280) * 1025..(n / 1280 + 1) * 1025];
                let voiced = row
                    .iter()
                    .enumerate()
                    .max_by(|a, b| a.1.total_cmp(b.1))
                    .unwrap()
                    .0
                    != 1024;
                n as f32 / 1e8 + if voiced { 0.1 } else { 0. }
            })
            .collect();
        let mut spot = Spotter::new(
            ReplayWindow { logits },
            corpus.clone(),
            SpotConfig {
                window_seconds: window as f64,
                ..Default::default()
            },
        )
        .unwrap();
        let mut events = vec![];
        for chunk in pcm.chunks(4800) {
            events.extend(spot.feed(chunk).unwrap());
        }
        let summary = spot.stop().unwrap();
        events.extend(summary.events);
        let quote_events: Vec<_> = events
            .into_iter()
            .filter_map(|e| {
                if let Event::QuoteDetected { quote } = e {
                    Some(quote)
                } else {
                    None
                }
            })
            .collect();
        let fp = quote_events
            .iter()
            .filter(|q| {
                q.verified
                    && (q.surah != Some(78) || q.ayah_from != Some(2) || q.ayah_to != Some(2))
            })
            .count();
        let matched = usize::from(quote_events.iter().any(|q| fully_covers(q, &corpus, 78, 2)));
        receipt(
            "closed_ambiguity_with_later_seed",
            window,
            matched,
            1,
            fp,
            &quote_events,
        );
        false_positives.push(fp);
        assert_eq!(matched, 1, "{quote_events:?}");
        assert!(quote_events
            .iter()
            .any(|q| q.ambiguous && !q.verified && q.surah.is_none()));
        assert_eq!(summary.quotes, quote_events);
    }
    assert_eq!(false_positives, vec![0, 0]);
}
