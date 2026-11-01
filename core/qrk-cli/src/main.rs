use clap::{Parser, Subcommand};
use futures_util::{SinkExt, StreamExt};
use qrk_audio::{AudioResampler, Capture};
use qrk_core::{Config, Event, Target};
use qrk_onnx::{load_corpus, ModelPack, Recognizer};
use serde_json::{json, Value};
use std::{
    io::{self, BufRead, Write},
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
    Model {
        #[command(subcommand)]
        command: ModelCommand,
    },
    Devices,
    Wav {
        #[arg(long)]
        surah: u16,
        #[arg(long)]
        ayahs: Option<String>,
        file: PathBuf,
    },
    Mic {
        #[arg(long)]
        surah: u16,
        #[arg(long)]
        device: Option<String>,
        #[arg(long)]
        seconds: Option<f64>,
    },
    Serve {
        #[arg(long, default_value_t = 7877)]
        port: u16,
        #[arg(long)]
        token: Option<String>,
        #[arg(long)]
        stdio: bool,
    },
    Selftest,
}
#[derive(Subcommand)]
enum ModelCommand {
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
fn recognizer(args: &Args) -> AnyResult<Recognizer> {
    let model = if let Some(dir) = &args.model {
        ModelPack::from_directory(dir)?
    } else {
        ModelPack::fetch(None, |_| {})?
    };
    Ok(Recognizer::new(
        model,
        load_corpus(args.corpus.as_deref())?,
        Config::default(),
    )?)
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
fn wav(args: &Args, surah: u16, ayahs: Option<&str>, file: &Path) -> AnyResult<i32> {
    let mut engine = recognizer(args)?;
    let expected = target(surah, ayahs)?;
    let count = match expected {
        Target::Ayahs { from, to, .. } => usize::from(to.saturating_sub(from) + 1),
        _ => engine_corpus_count(args, surah)?,
    };
    engine.set_expected(expected)?;
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
            mono.push(frame.iter().sum::<f32>() / format.channels as f32);
            frame.clear();
        }
        if mono.len() >= 1024 {
            pending.extend(resampler.process(&mono)?);
            mono.clear();
            while pending.len() >= 4800 {
                let chunk: Vec<_> = pending.drain(..4800).collect();
                events(&engine.feed(&chunk), args.json);
            }
        }
    }
    pending.extend(resampler.process(&mono)?);
    pending.extend(resampler.finish()?);
    if !pending.is_empty() {
        events(&engine.feed(&pending), args.json)
    }
    let summary = engine.stop()?;
    events(&summary.events, args.json);
    println!(
        "{}",
        json!({"type":"summary","verses":summary.verses,"transcript":summary.transcript,"duration":summary.duration})
    );
    Ok(if summary.verses.len() == count { 0 } else { 1 })
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
) -> AnyResult<i32> {
    let mut engine = recognizer(args)?;
    engine.set_expected(Target::surah(surah))?;
    let (sender, receiver) = std::sync::mpsc::sync_channel(64);
    let capture = Capture::start(device, sender)?;
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
                events(&engine.feed(&pending), args.json);
                pending.clear();
            }
        }
    }
    let dropped = capture.dropped_chunks();
    drop(capture);
    while let Ok(chunk) = receiver.try_recv() {
        pending.extend(resampler.process(&chunk)?);
    }
    pending.extend(resampler.finish()?);
    if !pending.is_empty() {
        events(&engine.feed(&pending), args.json)
    }
    if dropped > 0 {
        eprintln!(
            "Capture overrun: {dropped} input chunks lost; check this result before relying on it."
        );
    }
    let summary = engine.stop()?;
    events(&summary.events, args.json);
    println!(
        "{}",
        json!({"type":"summary","verses":summary.verses,"transcript":summary.transcript,"duration":summary.duration,"dropped_chunks":dropped})
    );
    Ok(0)
}
#[tokio::main]
async fn main() {
    let args = Args::parse();
    let result: AnyResult<i32> = match &args.command {
        Command::Model {
            command: ModelCommand::Fetch { cache },
        } => ModelPack::fetch(cache.as_deref(), |p| eprint!("\rModel: {:.0}%", p * 100.))
            .map(|p| {
                eprintln!();
                println!("{}", p.model_path.parent().unwrap().display());
                0
            })
            .map_err(Into::into),
        Command::Devices => qrk_audio::devices()
            .map(|d| {
                println!("{}", json!(d));
                0
            })
            .map_err(Into::into),
        Command::Wav { surah, ayahs, file } => wav(&args, *surah, ayahs.as_deref(), file),
        Command::Mic {
            surah,
            device,
            seconds,
        } => mic(&args, *surah, device.as_deref(), *seconds).await,
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
