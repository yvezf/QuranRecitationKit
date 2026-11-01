//! Explicit candidate validation. No candidate is selected by the SDK downloader here.
use clap::Parser;
use qrk_audio::AudioResampler;
use qrk_core::{Config, Event, RetryReason, Target};
use qrk_onnx::{load_corpus, validate_file, ModelPack, Recognizer};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::BTreeSet, fs, path::PathBuf};

#[derive(Parser)]
struct Args {
    #[arg(long)]
    baseline: PathBuf,
    #[arg(long)]
    candidate: PathBuf,
    #[arg(long)]
    report: PathBuf,
    /// Local owner-provided recording. Never supplied to the hosted workflow.
    #[arg(long)]
    wav: Option<PathBuf>,
}

#[derive(Deserialize)]
struct Candidate {
    file: String,
    sha256: String,
    size: u64,
}

fn run(
    engine: &mut Recognizer,
    pcm: &[f32],
    surah: u16,
    chunk: usize,
) -> Result<Value, Box<dyn std::error::Error>> {
    engine.set_expected(Target::Ayahs {
        surah,
        from: 1,
        to: 1,
    })?;
    let mut progress = 0;
    for block in pcm.chunks(chunk) {
        for event in engine.feed(block) {
            if let Event::WordProgress {
                matched_word_indices,
                ..
            } = event
            {
                progress = progress.max(matched_word_indices.len());
            }
        }
    }
    let summary = engine.stop()?;
    let verses: Vec<_> = summary.verses.iter().map(|v| (v.surah, v.ayah)).collect();
    let retries: BTreeSet<_> = summary
        .events
        .iter()
        .filter_map(|e| match e {
            Event::NeedsRetry { reason } => Some(match reason {
                RetryReason::Noise => "noise",
                RetryReason::TooShort => "too_short",
                RetryReason::Inconclusive => "inconclusive",
                RetryReason::OffTarget => "off_target",
            }),
            _ => None,
        })
        .collect();
    Ok(json!({"verses":verses,"retry_reasons":retries,"maximum_provisional_words":progress}))
}

fn pcm_from_wav(path: &PathBuf) -> Result<Vec<f32>, Box<dyn std::error::Error>> {
    let mut wav = hound::WavReader::open(path)?;
    let format = wav.spec();
    if format.channels == 0 || format.bits_per_sample > 32 {
        return Err("unsupported WAV format".into());
    }
    let samples: Vec<f32> = if format.sample_format == hound::SampleFormat::Float {
        wav.samples::<f32>().collect::<Result<_, _>>()?
    } else {
        let scale = (1u64 << (format.bits_per_sample - 1)) as f32;
        wav.samples::<i32>()
            .map(|v| v.map(|x| x as f32 / scale))
            .collect::<Result<_, _>>()?
    };
    let mono: Vec<f32> = samples
        .chunks(format.channels as usize)
        .map(|x| x.iter().sum::<f32>() / x.len() as f32)
        .collect();
    let mut resampler = AudioResampler::new(format.sample_rate)?;
    let mut pcm = vec![];
    for chunk in mono.chunks(1024) {
        pcm.extend(resampler.process(chunk)?);
    }
    pcm.extend(resampler.finish()?);
    Ok(pcm)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let metadata: Candidate =
        serde_json::from_slice(&fs::read(args.candidate.join("candidate.json"))?)?;
    if PathBuf::from(&metadata.file)
        .file_name()
        .and_then(|x| x.to_str())
        != Some(metadata.file.as_str())
    {
        return Err("candidate file must be a plain filename".into());
    }
    let model = args.candidate.join(&metadata.file);
    validate_file(&model, metadata.size, &metadata.sha256)?;
    let corpus = load_corpus(None)?;
    let mut baseline = Recognizer::new(
        ModelPack::from_directory(&args.baseline)?,
        corpus.clone(),
        Config::default(),
    )?;
    let mut candidate =
        Recognizer::new(ModelPack { model_path: model }, corpus, Config::default())?;
    let mut cases = vec![];
    for samples in [16000, 32000, 48000, 192000] {
        for hz in [110, 220, 440] {
            let pcm: Vec<_> = (0..samples)
                .map(|i| 0.02 * (2. * std::f32::consts::PI * hz as f32 * (i as f32 / 16000.)).sin())
                .collect();
            let old = run(&mut baseline, &pcm, 78, 4800)?;
            let new = run(&mut candidate, &pcm, 78, 4800)?;
            let passed = old["verses"] == json!([])
                && new["verses"] == json!([])
                && old["retry_reasons"]
                    .as_array()
                    .is_some_and(|v| !v.is_empty())
                && new["retry_reasons"]
                    .as_array()
                    .is_some_and(|v| !v.is_empty());
            cases.push(json!({"fixture":format!("tone-{samples}-{hz}"),"passed":passed,"retry_reasons_equal":old["retry_reasons"]==new["retry_reasons"],"baseline":old,"candidate":new}));
        }
    }
    for (name, pcm) in [
        ("silence", vec![0.; 32000]),
        ("very_short", vec![0.02; 320]),
        ("dc_offset", vec![0.02; 32000]),
    ] {
        let old = run(&mut baseline, &pcm, 78, 4800)?;
        let new = run(&mut candidate, &pcm, 78, 4800)?;
        let passed = old["verses"] == json!([])
            && new["verses"] == json!([])
            && old["retry_reasons"]
                .as_array()
                .is_some_and(|v| !v.is_empty())
            && new["retry_reasons"]
                .as_array()
                .is_some_and(|v| !v.is_empty());
        cases.push(json!({"fixture":name,"passed":passed,"retry_reasons_equal":old["retry_reasons"]==new["retry_reasons"],"baseline":old,"candidate":new}));
    }
    let mut local_cases = vec![];
    if let Some(path) = &args.wav {
        let pcm = pcm_from_wav(path)?;
        for gain in [0.5, 1., 2.] {
            let scaled: Vec<_> = pcm.iter().map(|x| (x * gain).clamp(-1., 1.)).collect();
            for chunk in [1600, 4800, 16000] {
                let old = run(&mut baseline, &scaled, 78, chunk)?;
                let new = run(&mut candidate, &scaled, 78, chunk)?;
                let passed = old["verses"] == json!([[78, 1]]) && new["verses"] == json!([[78, 1]]);
                local_cases.push(json!({"fixture":format!("owned-gain-{gain}-chunk-{chunk}"),"passed":passed,"retry_reasons_equal":old["retry_reasons"]==new["retry_reasons"],"baseline":old,"candidate":new}));
            }
        }
        for surah in [1, 95, 97, 112] {
            let old = run(&mut baseline, &pcm, surah, 4800)?;
            let new = run(&mut candidate, &pcm, surah, 4800)?;
            let passed = old["verses"] == json!([]) && new["verses"] == json!([]);
            local_cases.push(json!({"fixture":format!("owned-wrong-target-{surah}"),"passed":passed,"retry_reasons_equal":old["retry_reasons"]==new["retry_reasons"],"baseline":old,"candidate":new}));
        }
        let short = &pcm[..pcm.len().min(1600)];
        let old = run(&mut baseline, short, 78, 4800)?;
        let new = run(&mut candidate, short, 78, 4800)?;
        let passed = old["verses"] == json!([]) && new["verses"] == json!([]);
        local_cases.push(json!({"fixture":"owned-truncated-100ms","passed":passed,"retry_reasons_equal":old["retry_reasons"]==new["retry_reasons"],"baseline":old,"candidate":new}));
    }
    let passed = cases
        .iter()
        .chain(local_cases.iter())
        .all(|x| x["passed"] == true);
    let report = json!({
        "passed":passed,
        "synthetic_decision_parity":cases.iter().all(|x| x["passed"] == true),
        "retry_reason_matches":cases.iter().filter(|x| x["retry_reasons_equal"] == true).count(),
        "candidate_sha256":metadata.sha256,
        "cases":cases,
        "local_recording":if args.wav.is_some() { "run_locally" } else { "not_run" },
        "local_cases":local_cases,
        "scope":"Public acceptance/retry decisions; raw non-speech decoder strings are recorded separately. No audio is stored in this report."
    });
    if let Some(parent) = args.report.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(
        &args.report,
        format!("{}\n", serde_json::to_string_pretty(&report)?),
    )?;
    println!("{}", json!({"passed":passed,"report":args.report}));
    if !passed {
        std::process::exit(1);
    }
    Ok(())
}
