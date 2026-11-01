use crate::{Error, Result};
#[derive(Clone, Debug, PartialEq)]
pub struct Decode {
    pub text: String,
    pub tokens: Vec<u32>,
    pub frames: Vec<u32>,
}
pub fn collapse(frames: &[u32], blank: u32) -> Vec<u32> {
    let mut previous = None;
    frames
        .iter()
        .filter_map(|t| {
            let emit = Some(*t) != previous && *t != blank;
            previous = Some(*t);
            emit.then_some(*t)
        })
        .collect()
}
pub fn decode(
    logits: &[f32],
    time: usize,
    vocab: usize,
    pieces: &[String],
    blank: u32,
) -> Result<Decode> {
    validate(logits, time, vocab, &[], blank)?;
    let mut frames = Vec::with_capacity(time);
    for row in logits.chunks_exact(vocab) {
        let mut best = None;
        for (i, x) in row.iter().enumerate() {
            if x.is_nan() {
                continue;
            }
            if best.is_none_or(|(_, y)| *x > y) {
                best = Some((i, *x));
            }
        }
        frames.push(
            best.ok_or_else(|| Error::Invalid("NaN-only CTC frame".into()))?
                .0 as u32,
        );
    }
    let tokens = collapse(&frames, blank);
    let text = tokens
        .iter()
        .filter_map(|i| pieces.get(*i as usize))
        .filter(|s| *s != "<unk>" && *s != "<blank>")
        .cloned()
        .collect::<String>()
        .replace('▁', " ");
    Ok(Decode {
        text: crate::text::normalize_arabic(&text),
        tokens,
        frames,
    })
}
fn validate(logits: &[f32], time: usize, vocab: usize, target: &[u32], blank: u32) -> Result<()> {
    if time == 0
        || vocab == 0
        || blank as usize >= vocab
        || time.checked_mul(vocab) != Some(logits.len())
        || target.iter().any(|t| *t == blank || *t as usize >= vocab)
    {
        return Err(Error::Invalid("CTC shape or target is invalid".into()));
    }
    if logits.iter().any(|x| !x.is_finite()) {
        return Err(Error::Invalid("CTC values must be finite".into()));
    }
    Ok(())
}
fn log_add(a: f64, b: f64) -> f64 {
    if a == f64::NEG_INFINITY {
        return b;
    }
    if b == f64::NEG_INFINITY {
        return a;
    }
    let hi = a.max(b);
    hi + (-(a - b).abs()).exp().ln_1p()
}
fn token(state: usize, target: &[u32], blank: u32) -> u32 {
    if state.is_multiple_of(2) {
        blank
    } else {
        target[state / 2]
    }
}
pub fn score(logits: &[f32], time: usize, vocab: usize, target: &[u32], blank: u32) -> Result<f64> {
    validate(logits, time, vocab, target, blank)?;
    let states = target.len() * 2 + 1;
    let mut prev = vec![f64::NEG_INFINITY; states];
    prev[0] = logits[blank as usize] as f64;
    if states > 1 {
        prev[1] = logits[target[0] as usize] as f64
    }
    for t in 1..time {
        let mut next = vec![f64::NEG_INFINITY; states];
        for s in 0..states {
            let id = token(s, target, blank);
            let mut p = prev[s];
            if s > 0 {
                p = log_add(p, prev[s - 1]);
            }
            if s > 1 && id != blank && id != token(s - 2, target, blank) {
                p = log_add(p, prev[s - 2]);
            }
            next[s] = p + logits[t * vocab + id as usize] as f64;
        }
        prev = next;
    }
    let terminal = if states == 1 {
        prev[0]
    } else {
        log_add(prev[states - 1], prev[states - 2])
    };
    if !terminal.is_finite() {
        return Err(Error::Invalid("unreachable CTC target".into()));
    }
    Ok(terminal / time as f64)
}
/// Highest-probability CTC path. Ties: stay, advance one, advance two; final blank wins.
pub fn forced_alignment(
    logits: &[f32],
    time: usize,
    vocab: usize,
    target: &[u32],
    blank: u32,
) -> Result<Vec<(usize, usize)>> {
    validate(logits, time, vocab, target, blank)?;
    let required = target.len() + target.windows(2).filter(|p| p[0] == p[1]).count();
    if target.is_empty() || time < required {
        return Err(Error::Invalid("unreachable CTC alignment".into()));
    }
    let n = target.len() * 2 + 1;
    let mut trace = vec![u8::MAX; time * n];
    let mut prev = vec![f64::NEG_INFINITY; n];
    prev[0] = logits[blank as usize] as f64;
    prev[1] = logits[target[0] as usize] as f64;
    for t in 1..time {
        let mut next = vec![f64::NEG_INFINITY; n];
        for s in 0..n {
            let id = token(s, target, blank);
            let mut best = prev[s];
            let mut delta = if best.is_finite() { 0 } else { u8::MAX };
            if s > 0 && prev[s - 1] > best {
                best = prev[s - 1];
                delta = 1;
            }
            if s > 1 && id != blank && id != token(s - 2, target, blank) && prev[s - 2] > best {
                best = prev[s - 2];
                delta = 2;
            }
            next[s] = best + logits[t * vocab + id as usize] as f64;
            trace[t * n + s] = delta;
        }
        prev = next;
    }
    let mut s = if prev[n - 1] >= prev[n - 2] {
        n - 1
    } else {
        n - 2
    };
    if !prev[s].is_finite() {
        return Err(Error::Invalid("unreachable CTC alignment".into()));
    }
    let mut ranges = vec![(usize::MAX, 0); target.len()];
    for t in (0..time).rev() {
        if s % 2 == 1 {
            let r = &mut ranges[s / 2];
            r.0 = r.0.min(t);
            r.1 = r.1.max(t + 1);
        }
        if t > 0 {
            let d = trace[t * n + s];
            if d == u8::MAX || d as usize > s {
                return Err(Error::Invalid("CTC traceback failed".into()));
            }
            s -= d as usize;
        }
    }
    if ranges.iter().any(|r| r.0 == usize::MAX) {
        return Err(Error::Invalid("unemitted CTC token".into()));
    }
    Ok(ranges)
}
#[derive(Clone, Debug, Default)]
pub struct TokenProgress {
    pub words: usize,
    pub matched_tokens: usize,
    pub first: Option<usize>,
    pub last: Option<usize>,
}
pub fn token_progress(
    frames: &[u32],
    target: &[u32],
    ends: &[usize],
    minimum: usize,
    blank: u32,
) -> TokenProgress {
    let mut emissions = Vec::new();
    let mut prior = None;
    for (frame, t) in frames.iter().enumerate() {
        if Some(*t) != prior && *t != blank {
            emissions.push((frame, *t));
        }
        prior = Some(*t);
    }
    let mut best = TokenProgress::default();
    for start in 0..emissions.len() {
        if emissions[start].0 < minimum {
            continue;
        }
        let mut n = 0;
        while n < target.len() && start + n < emissions.len() && emissions[start + n].1 == target[n]
        {
            n += 1;
        }
        if n > 0 && n >= best.matched_tokens {
            best = TokenProgress {
                words: ends.iter().take_while(|x| **x <= n).count(),
                matched_tokens: n,
                first: Some(emissions[start].0),
                last: Some(emissions[start + n - 1].0),
            };
        }
    }
    best
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn collapse_repeats_and_blank() {
        assert_eq!(collapse(&[1, 1, 3, 1, 2, 2, 3], 3), vec![1, 1, 2]);
    }
    #[test]
    fn rank_and_align() {
        let frames = [0, 1, 1, 0, 2, 2, 0];
        let mut x = vec![-9.; 28];
        for (t, id) in frames.iter().enumerate() {
            x[t * 4 + id] = -0.01;
        }
        assert!(score(&x, 7, 4, &[1, 2], 0).unwrap() > score(&x, 7, 4, &[2, 1], 0).unwrap());
        assert_eq!(
            forced_alignment(&x, 7, 4, &[1, 2], 0).unwrap(),
            vec![(1, 3), (4, 6)]
        );
    }
    #[test]
    fn blank_target() {
        assert_eq!(score(&[-1., -2., -1., -2.], 2, 2, &[], 0).unwrap(), -1.);
    }
    #[test]
    fn malformed() {
        assert!(score(&[], 0, 4, &[], 0).is_err());
        assert!(forced_alignment(&[0.; 4], 1, 4, &[1, 1], 0).is_err());
    }
}
#[cfg(test)]
mod shared_fixture_tests {
    use super::*;
    #[derive(serde::Deserialize)]
    struct Fixture {
        name: String,
        time: usize,
        vocab: usize,
        blank: u32,
        logits: Vec<f32>,
        target: Vec<u32>,
        score_per_frame: f64,
        alignment: Vec<(usize, usize)>,
    }
    #[test]
    fn same_fixture_as_swift() {
        let fixtures: Vec<Fixture> =
            serde_json::from_str(include_str!("../../../tests/fixtures/scorer.json")).unwrap();
        for f in fixtures {
            assert!(
                (score(&f.logits, f.time, f.vocab, &f.target, f.blank).unwrap()
                    - f.score_per_frame)
                    .abs()
                    < 1e-4,
                "{}",
                f.name
            );
            if !f.target.is_empty() {
                assert_eq!(
                    forced_alignment(&f.logits, f.time, f.vocab, &f.target, f.blank).unwrap(),
                    f.alignment,
                    "{}",
                    f.name
                );
            }
        }
    }
}
