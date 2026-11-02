use clap::{Parser, Subcommand};
use futures_util::{SinkExt, StreamExt};
use qrk_audio::{AudioResampler, Capture};
use qrk_core::{Config, Event, SpotConfig, Summary, Target};
use qrk_onnx::{load_corpus, ModelPack, Recognizer};
use serde_json::{json, Value};
use std::{
    io::{self, BufRead, IsTerminal, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
mod sidecar;
type AnyResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;
#[derive(Parser)]
#[command(
    name = "qrk",
    version,
    about = "Offline expected-text Quran recitation tracking"
)]
struct Args {
    #[arg(long, global = true, env = "QRK_MODEL_DIR")]
    model: Option<PathBuf>,
    #[arg(long, global = true)]
    corpus: Option<PathBuf>,
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Download and verify the pinned offline model.
    Model {
        #[command(subcommand)]
        command: ModelCommand,
    },
    /// List usable microphone input devices.
    Devices,
    /// Track an expected surah or ayah range in a WAV file.
    Wav {
        #[arg(long)]
        surah: u16,
        #[arg(long)]
        ayahs: Option<String>,
        file: PathBuf,
    },
    /// Track live microphone audio (explicit capture permission required).
    Mic {
        #[arg(long)]
        surah: u16,
        #[arg(long)]
        device: Option<String>,
        #[arg(long)]
        seconds: Option<f64>,
    },
    /// Detect Quran quotations in a WAV file or microphone stream, without a target.
    Spot {
        #[arg(long, required_unless_present = "mic", conflicts_with = "mic")]
        wav: Option<PathBuf>,
        #[arg(long, required_unless_present = "wav")]
        mic: bool,
        #[arg(long, requires = "mic")]
        device: Option<String>,
        #[arg(long, requires = "mic")]
        seconds: Option<f64>,
        #[arg(long, default_value_t = 8.0)]
        window_seconds: f64,
    },
    /// Model-free transcript candidates, always unverified.
    MatchText { text: String },
    /// Run the local WebSocket or stdio JSON/PCM sidecar.
    Serve {
        #[arg(long, default_value_t = 7877)]
        port: u16,
        #[arg(long)]
        token: Option<String>,
        #[arg(long)]
        stdio: bool,
    },
    /// Check the bundled Quran corpus and tokenizer without a model.
    Selftest,
}
#[derive(Subcommand)]
enum ModelCommand {
    /// Explicit one-time download with size and SHA-256 verification.
    Fetch {
        #[arg(long)]
        cache: Option<PathBuf>,
    },
}
fn target(surah: u16, ayahs: Option<&str>) -> AnyResult<Target> {
    if let Some(range) = ayahs {
        let (a, b) = range.split_once('-').ok_or("ayah range must be a-b")?;
        Ok(Target::Ayahs {
            surah,
            from: a.parse()?,
            to: b.parse()?,
        })
    } else {
        Ok(Target::surah(surah))
    }
}
enum Engine {
    Tracking(Recognizer),
    Spot(qrk_onnx::Spotter),
}
impl Engine {
    fn feed(&mut self, pcm: &[f32]) -> qrk_core::Result<Vec<Event>> {
        match self {
            Self::Tracking(r) => Ok(r.feed(pcm)),
            Self::Spot(r) => r.feed(pcm),
        }
    }
    fn stop(&mut self) -> qrk_core::Result<Summary> {
        match self {
            Self::Tracking(r) => r.stop(),
            Self::Spot(r) => r.stop(),
        }
    }
    fn target(&mut self, target: Target) -> qrk_core::Result<()> {
        match self {
            Self::Tracking(r) => r.set_expected(target),
            Self::Spot(_) => Err(qrk_core::Error::Invalid(
                "spot mode has no expected target".into(),
            )),
        }
    }
}
fn engine(args: &Args, spot: Option<SpotConfig>) -> AnyResult<Engine> {
    let model = if let Some(dir) = &args.model {
        ModelPack::from_directory(dir)?
    } else {
        ModelPack::fetch(None, |_| {})?
    };
    let corpus = load_corpus(args.corpus.as_deref())?;
    Ok(if let Some(config) = spot {
        Engine::Spot(qrk_onnx::Spotter::new(model, corpus, config)?)
    } else {
        Engine::Tracking(Recognizer::new(model, corpus, Config::default())?)
    })
}
fn events(events: &[Event], machine: bool) {
    for event in events {
        if machine {
            println!("{}", serde_json::to_string(event).unwrap())
        } else {
            println!("{event:?}")
        }
    }
    let _ = io::stdout().flush();
}
fn wav(
    args: &Args,
    surah: u16,
    ayahs: Option<&str>,
    file: &Path,
    spot: Option<SpotConfig>,
) -> AnyResult<i32> {
    let spotting = spot.is_some();
    let mut engine = engine(args, spot)?;
    let expected = if spotting {
        Target::surah(1)
    } else {
        target(surah, ayahs)?
    };
    let count = if spotting {
        0
    } else {
        match expected {
            Target::Ayahs { from, to, .. } => usize::from(to.saturating_sub(from) + 1),
            _ => engine_corpus_count(args, surah)?,
        }
    };
    if !spotting {
        engine.target(expected)?;
    }
    let mut wav = hound::WavReader::open(file)?;
    let format = wav.spec();
    if format.channels == 0 {
        return Err("WAV has no channels".into());
    }
    let mut resampler = AudioResampler::new(format.sample_rate)?;
    let mut mono = vec![];
    let mut pending = vec![];
    let mut frame = vec![];
    let samples: Box<dyn Iterator<Item = AnyResult<f32>>> =
        if format.sample_format == hound::SampleFormat::Float {
            Box::new(wav.samples::<f32>().map(|s| s.map_err(Into::into)))
        } else {
            let scale = (1u64 << (format.bits_per_sample - 1)) as f32;
            Box::new(
                wav.samples::<i32>()
                    .map(move |s| s.map(|v| v as f32 / scale).map_err(Into::into)),
            )
        };
    for sample in samples {
        frame.push(sample?);
        if frame.len() == format.channels as usize {
            mono.push(qrk_audio::downmix_frame(&frame));
            frame.clear();
        }
        if mono.len() >= 1024 {
            if !frame.is_empty() {
                return Err("WAV ends with an incomplete channel frame".into());
            }
            pending.extend(resampler.process(&mono)?);
            mono.clear();
            while pending.len() >= 4800 {
                let chunk: Vec<_> = pending.drain(..4800).collect();
                events(&engine.feed(&chunk)?, args.json);
            }
        }
    }
    pending.extend(resampler.process(&mono)?);
    pending.extend(resampler.finish()?);
    if !pending.is_empty() {
        events(&engine.feed(&pending)?, args.json)
    }
    let summary = engine.stop()?;
    events(&summary.events, args.json);
    println!(
        "{}",
        json!({"type":"summary","verses":summary.verses,"quotes":summary.quotes,"transcript":summary.transcript,"duration":summary.duration})
    );
    Ok(if spotting || summary.verses.len() == count {
        0
    } else {
        1
    })
}
fn engine_corpus_count(args: &Args, surah: u16) -> AnyResult<usize> {
    Ok(load_corpus(args.corpus.as_deref())?
        .surahs
        .iter()
        .find(|s| s.number == surah)
        .ok_or("unknown surah")?
        .ayah_count as usize)
}
async fn mic(
    args: &Args,
    surah: u16,
    device: Option<&str>,
    seconds: Option<f64>,
    spot: Option<SpotConfig>,
) -> AnyResult<i32> {
    if seconds.is_some_and(|s| !s.is_finite() || s <= 0.) {
        return Err("microphone duration must be finite and positive".into());
    }
    qrk_audio::quiet_device_probe(|| qrk_audio::check_input_device(device))?;
    let spotting = spot.is_some();
    let mut engine = engine(args, spot)?;
    if !spotting {
        engine.target(Target::surah(surah))?;
    }
    let (sender, receiver) = std::sync::mpsc::sync_channel(64);
    let capture = qrk_audio::quiet_device_probe(|| Capture::start(device, sender))?;
    let mut resampler = AudioResampler::new(capture.sample_rate)?;
    let stop = Arc::new(AtomicBool::new(false));
    let signal = stop.clone();
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        signal.store(true, Ordering::SeqCst);
    });
    let input = stop.clone();
    std::thread::spawn(move || {
        for line in io::stdin().lock().lines().map_while(Result::ok) {
            if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["type"] == "stop") {
                input.store(true, Ordering::SeqCst);
                break;
            }
        }
    });
    eprintln!(
        "Microphone ready: {} Hz, {} channels. Ctrl-C or a stop JSON line ends capture.",
        capture.sample_rate, capture.channels
    );
    let started = Instant::now();
    let mut pending = vec![];
    while !stop.load(Ordering::SeqCst)
        && seconds.is_none_or(|s| started.elapsed().as_secs_f64() < s)
    {
        if let Some(error) = capture.failure() {
            return Err(error.into());
        }
        if let Ok(mut chunk) = receiver.recv_timeout(Duration::from_millis(50)) {
            while let Ok(more) = receiver.try_recv() {
                chunk.extend(more);
            }
            pending.extend(resampler.process(&chunk)?);
            if pending.len() >= 4800 {
                events(&engine.feed(&pending)?, args.json);
                pending.clear();
            }
        }
    }
    let dropped = capture.dropped_chunks();
    let mut received_audio = !pending.is_empty();
    drop(capture);
    while let Ok(chunk) = receiver.try_recv() {
        received_audio |= !chunk.is_empty();
        pending.extend(resampler.process(&chunk)?);
    }
    pending.extend(resampler.finish()?);
    if !pending.is_empty() {
        events(&engine.feed(&pending)?, args.json)
    }
    if dropped > 0 {
        eprintln!(
            "Capture overrun: {dropped} input chunks lost; check this result before relying on it."
        );
    }
    let summary = engine.stop()?;
    if !received_audio && summary.duration == 0. {
        return Err("no audio received from the input device".into());
    }
    events(&summary.events, args.json);
    println!(
        "{}",
        json!({"type":"summary","verses":summary.verses,"quotes":summary.quotes,"transcript":summary.transcript,"duration":summary.duration,"dropped_chunks":dropped})
    );
    Ok(if !spotting && summary.verses.is_empty() {
        1
    } else {
        0
    })
}
struct DownloadProgress {
    tty: bool,
    last: Option<u8>,
}
impl DownloadProgress {
    fn new(tty: bool) -> Self {
        Self { tty, last: None }
    }
    fn update(&mut self, fraction: f64) -> Option<String> {
        if !fraction.is_finite() {
            return None;
        }
        let mut percent = (fraction.clamp(0., 1.) * 100.).floor() as u8;
        if !self.tty {
            percent = percent / 10 * 10;
        }
        if self.last == Some(percent) {
            return None;
        }
        self.last = Some(percent);
        Some(if self.tty {
            format!("\rModel: {percent}%")
        } else {
            format!("Model: {percent}%\n")
        })
    }
}
#[tokio::main]
async fn main() {
    let args = Args::parse();
    let result: AnyResult<i32> = match &args.command {
        Command::Model {
            command: ModelCommand::Fetch { cache },
        } => {
            let mut progress =
                DownloadProgress::new(io::stdout().is_terminal() && io::stderr().is_terminal());
            ModelPack::fetch(cache.as_deref(), |p| {
                if let Some(message) = progress.update(p) {
                    eprint!("{message}");
                }
            })
            .map(|p| {
                if progress.tty {
                    eprintln!();
                }
                println!("{}", p.model_path.parent().unwrap().display());
                0
            })
            .map_err(Into::into)
        }
        Command::Devices => qrk_audio::quiet_device_probe(qrk_audio::devices)
            .map(|d| {
                println!("{}", json!(d));
                0
            })
            .map_err(Into::into),
        Command::Wav { surah, ayahs, file } => wav(&args, *surah, ayahs.as_deref(), file, None),
        Command::Mic {
            surah,
            device,
            seconds,
        } => mic(&args, *surah, device.as_deref(), *seconds, None).await,
        Command::Spot {
            wav: file,
            mic: _,
            device,
            seconds,
            window_seconds,
        } => {
            let config = SpotConfig {
                window_seconds: *window_seconds,
                ..Default::default()
            };
            if let Some(file) = file {
                wav(&args, 0, None, file, Some(config))
            } else {
                mic(&args, 0, device.as_deref(), *seconds, Some(config)).await
            }
        }
        Command::MatchText { text } => qrk_onnx::match_text(text)
            .map(|r| {
                println!("{}", serde_json::to_string(&r).unwrap());
                0
            })
            .map_err(Into::into),
        Command::Serve { port, token, stdio } => {
            sidecar::serve(&args, *port, token.as_deref(), *stdio)
                .await
                .map(|_| 0)
        }
        Command::Selftest => {
            let model = qrk_core::Corpus::bundled().and_then(|c| c.build_index());
            model.map(|c|{println!("{}",json!({"type":"selftest","surahs":c.surahs.len(),"ayahs":c.verses.len(),"ok":true}));0}).map_err(Into::into)
        }
    };
    match result {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("qrk: {error}");
            std::process::exit(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn piped_download_progress_is_limited_to_ten_percent_steps() {
        let mut p = DownloadProgress::new(false);
        let messages: Vec<_> = (0..=10000)
            .filter_map(|n| p.update(n as f64 / 10000.))
            .collect();
        assert_eq!(messages.len(), 11);
        assert_eq!(messages[0], "Model: 0%\n");
        assert_eq!(messages[10], "Model: 100%\n");
        assert!(messages.iter().all(|m| !m.contains('\r')));
    }
}
