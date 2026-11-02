//! Local-only owned-recording gate. No recording is a CI input or fixture.
use clap::Parser;
use qrk_audio::AudioResampler;
use qrk_core::{Config, Event, Target};
use qrk_onnx::{load_corpus, ModelPack, Recognizer};
use serde_json::json;
use std::{fs, path::PathBuf};
#[derive(Parser)]
struct Args {
    #[arg(long)]
    wav: PathBuf,
    #[arg(long)]
    model: Option<PathBuf>,
    #[arg(long)]
    report: PathBuf,
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let mut wav = hound::WavReader::open(&args.wav)?;
    let spec = wav.spec();
    if spec.channels == 0 || spec.bits_per_sample == 0 || spec.bits_per_sample > 32 {
        return Err("unsupported WAV format".into());
    }
    let samples: Vec<f32> = if spec.sample_format == hound::SampleFormat::Float {
        wav.samples::<f32>().collect::<Result<_, _>>()?
    } else {
        let scale = (1u64 << (spec.bits_per_sample - 1)) as f32;
        wav.samples::<i32>()
            .map(|x| x.map(|v| v as f32 / scale))
            .collect::<Result<_, _>>()?
    };
    let mono: Vec<_> = samples
        .chunks(spec.channels as usize)
        .map(|f| f.iter().sum::<f32>() / f.len() as f32)
        .collect();
    let mut resampler = AudioResampler::new(spec.sample_rate)?;
    let mut pcm = Vec::new();
    for chunk in mono.chunks(1024) {
        pcm.extend(resampler.process(chunk)?);
    }
    pcm.extend(resampler.finish()?);
    let corpus = load_corpus(None)?;
    let pack = if let Some(dir) = args.model {
        ModelPack::from_directory(dir)?
    } else {
        ModelPack::fetch(None, |_| {})?
    };
    let mut cases = Vec::new();
    for (name, target, expected, live) in [
        (
            "range_78_1_2",
            Target::Ayahs {
                surah: 78,
                from: 1,
                to: 2,
            },
            vec![1, 2],
            true,
        ),
        (
            "selected_78_1_1_continuing",
            Target::Ayahs {
                surah: 78,
                from: 1,
                to: 1,
            },
            vec![1],
            true,
        ),
        (
            "whole_surah_78_partial",
            Target::Surah(78),
            vec![1, 2],
            true,
        ),
        (
            "terminal_range_78_1_2",
            Target::Ayahs {
                surah: 78,
                from: 1,
                to: 2,
            },
            vec![1, 2],
            false,
        ),
        ("wrong_target_surah_1", Target::Surah(1), vec![], true),
    ] {
        let mut r = Recognizer::new(
            ModelPack {
                model_path: pack.model_path.clone(),
            },
            corpus.clone(),
            Config {
                live_tracking: live,
                ..Default::default()
            },
        )?;
        r.set_expected(target)?;
        let mut log = Vec::new();
        let mut consumed = 0;
        let mut transcript_confidences = Vec::new();
        for chunk in pcm.chunks(4800) {
            consumed += chunk.len();
            for event in r.feed(chunk) {
                if let Event::RawTranscript { confidence, .. } = &event {
                    transcript_confidences.push(*confidence);
                }
                if !matches!(event, Event::RawTranscript { .. }) {
                    log.push(json!({"phase":"feed","audio_seconds":consumed as f64/16000.,"event":event}));
                }
            }
        }
        let summary = r.stop()?;
        for event in &summary.events {
            if let Event::RawTranscript { confidence, .. } = event {
                transcript_confidences.push(*confidence);
            }
            if !matches!(event, Event::RawTranscript { .. }) {
                log.push(
                    json!({"phase":"stop","audio_seconds":pcm.len()as f64/16000.,"event":event}),
                );
            }
        }
        let actual: Vec<_> = summary.verses.iter().map(|v| v.ayah).collect();
        let before_stop = log.iter().any(|row| {
            row["phase"] == "feed"
                && row["event"]["type"] == "verse_match"
                && row["event"]["ayah"] == 1
        });
        let ayah_two_progress = log
            .iter()
            .any(|row| row["event"]["type"] == "word_progress" && row["event"]["ayah"] == 2);
        let wrong_rejected = !expected.is_empty()
            || log.iter().any(|row| {
                row["event"]["type"] == "needs_retry" && row["event"]["reason"] == "off_target"
            });
        let live_second = !live
            || !expected.contains(&2)
            || log.iter().any(|row| {
                row["phase"] == "feed"
                    && row["event"]["type"] == "verse_match"
                    && row["event"]["ayah"] == 2
            });
        let raw_confidence_valid = !transcript_confidences.is_empty()
            && transcript_confidences
                .iter()
                .all(|x| x.is_finite() && (0. ..=1.).contains(x))
            && transcript_confidences.iter().any(|x| *x > 0.);
        let passed = raw_confidence_valid
            && wrong_rejected
            && live_second
            && actual == expected
            && (!live || expected.is_empty() || before_stop)
            && (!expected.contains(&2) || ayah_two_progress);
        cases.push(json!({"case":name,"passed":passed,"verses":summary.verses,"events":log,"raw_confidence_valid":raw_confidence_valid}));
    }
    let passed = cases.iter().all(|c| c["passed"] == true);
    let report =
        json!({"passed":passed,"source":"local_owned_recording_no_audio_in_report","cases":cases});
    fs::write(
        &args.report,
        format!("{}\n", serde_json::to_string_pretty(&report)?),
    )?;
    println!("{}", json!({"passed":passed,"cases":cases.len()}));
    if !passed {
        std::process::exit(1);
    }
    Ok(())
}
