//! Disk/network/runtime boundary. The pure engine lives in qrk-core.
mod cache;
pub use cache::cache_directory;
use ort::{session::Session, value::Tensor};
use qrk_core::{
    AcousticModel, AcousticOutput, Config, Corpus, CorpusIndex, Error, Event, Result, Summary,
    Target,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
};
include!(concat!(env!("OUT_DIR"), "/embedded_runtime.rs"));
pub const MODEL_NAME: &str = "fastconformer_full_mixed.onnx";
pub const MODEL_RELEASE: &str = "model-v2";
pub const MODEL_SHA256: &str = "8771deacfa0d7cacc0116d5c4a27222dcfcf52a96e555a7e9d26ab265c7c8f09";
pub const MODEL_BYTES: u64 = 88_880_384;
pub const REPOSITORY_OWNER: &str = "yvezf";
pub const MODEL_MANIFEST: &str = include_str!("../../../model/model-manifest.json");
pub fn model_source_url() -> String {
    format!("https://github.com/{REPOSITORY_OWNER}/QuranRecitationKit/releases/download/{MODEL_RELEASE}/{MODEL_NAME}")
}
fn failure(e: impl std::fmt::Display) -> Error {
    Error::Model(e.to_string())
}
#[derive(Clone, Debug)]
pub struct ModelPack {
    pub model_path: PathBuf,
}
impl ModelPack {
    pub fn from_directory(directory: impl AsRef<Path>) -> Result<Self> {
        #[derive(Deserialize)]
        struct Manifest {
            model: Descriptor,
        }
        #[derive(Deserialize)]
        struct Descriptor {
            file: String,
            size: u64,
            sha256: String,
        }
        let manifest: Manifest = serde_json::from_slice(
            &fs::read(directory.as_ref().join("model-manifest.json")).map_err(failure)?,
        )
        .map_err(failure)?;
        if manifest.model.file != MODEL_NAME
            || manifest.model.size != MODEL_BYTES
            || manifest.model.sha256 != MODEL_SHA256
        {
            return Err(Error::Model("incompatible model manifest".into()));
        }
        let path = directory.as_ref().join(MODEL_NAME);
        validate_file(&path, MODEL_BYTES, MODEL_SHA256)?;
        Ok(Self { model_path: path })
    }
    pub fn fetch(cache: Option<&Path>, mut progress: impl FnMut(f64)) -> Result<Self> {
        let directory = match cache {
            Some(path) => path.to_owned(),
            None => cache_directory()?.join(MODEL_RELEASE),
        };
        if let Ok(pack) = Self::from_directory(&directory) {
            progress(1.);
            return Ok(pack);
        }
        if REPOSITORY_OWNER.starts_with('<') {
            return Err(Error::Model("model release is not configured; set REPOSITORY_OWNER or use a local --model directory".into()));
        }
        fs::create_dir_all(&directory).map_err(failure)?;
        let url = model_source_url();
        let mut response = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(600))
            .build()
            .map_err(failure)?
            .get(url)
            .send()
            .map_err(failure)?
            .error_for_status()
            .map_err(failure)?;
        let temporary = directory.join(format!(
            ".download-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let outcome = (|| {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
                .map_err(failure)?;
            let mut bytes = 0;
            let mut buffer = [0; 65536];
            progress(0.);
            loop {
                let n = response.read(&mut buffer).map_err(failure)?;
                if n == 0 {
                    break;
                }
                bytes += n as u64;
                if bytes > MODEL_BYTES {
                    return Err(Error::Model("model download exceeds pinned size".into()));
                }
                file.write_all(&buffer[..n]).map_err(failure)?;
                progress((bytes as f64 / MODEL_BYTES as f64).min(0.99));
            }
            file.sync_all().map_err(failure)?;
            validate_file(&temporary, MODEL_BYTES, MODEL_SHA256)?;
            let dest = directory.join(MODEL_NAME);
            if dest.exists() {
                fs::remove_file(&dest).map_err(failure)?;
            }
            fs::rename(&temporary, dest).map_err(failure)?;
            let manifest_temp = directory.join(".model-manifest.tmp");
            fs::write(&manifest_temp, MODEL_MANIFEST).map_err(failure)?;
            let manifest_dest = directory.join("model-manifest.json");
            if manifest_dest.exists() {
                fs::remove_file(&manifest_dest).map_err(failure)?;
            }
            fs::rename(manifest_temp, manifest_dest).map_err(failure)?;
            progress(1.);
            Self::from_directory(&directory)
        })();
        let _ = fs::remove_file(temporary);
        outcome
    }
}
pub fn validate_file(path: &Path, expected_size: u64, expected_sha: &str) -> Result<()> {
    let metadata = fs::metadata(path).map_err(failure)?;
    if !metadata.is_file() || metadata.len() != expected_size {
        return Err(Error::Model("model size/type mismatch".into()));
    }
    let mut f = fs::File::open(path).map_err(failure)?;
    let mut digest = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let n = f.read(&mut buffer).map_err(failure)?;
        if n == 0 {
            break;
        }
        digest.update(&buffer[..n]);
    }
    if hex::encode(digest.finalize()) != expected_sha {
        return Err(Error::Model("model SHA256 mismatch".into()));
    }
    Ok(())
}
pub fn load_corpus(path: Option<&Path>) -> Result<Arc<CorpusIndex>> {
    let corpus = if let Some(path) = path {
        Corpus::from_json(&fs::read_to_string(path).map_err(failure)?)?
    } else {
        Corpus::bundled()?
    };
    let key = corpus.cache_key();
    let directory = cache_directory()?.join("indices");
    let cached = directory.join(format!("{key}.json"));
    if let Ok(bytes) = fs::read(&cached) {
        if let Ok(index) = serde_json::from_slice::<CorpusIndex>(&bytes) {
            if corpus.validates_index(&index) {
                return Ok(Arc::new(index));
            }
        }
    }
    let index = corpus.build_index()?;
    if fs::create_dir_all(&directory).is_ok() {
        if let Ok(bytes) = serde_json::to_vec(&index) {
            let temp = directory.join(format!("{key}.{}.tmp", std::process::id()));
            if fs::write(&temp, bytes).is_ok() {
                let _ = fs::rename(&temp, &cached);
            }
            let _ = fs::remove_file(temp);
        }
    }
    Ok(Arc::new(index))
}
pub struct OnnxRunner {
    session: Session,
}
impl OnnxRunner {
    pub fn new(pack: &ModelPack) -> Result<Self> {
        static INIT: OnceLock<()> = OnceLock::new();
        static LOCK: Mutex<()> = Mutex::new(());
        let _guard = LOCK
            .lock()
            .map_err(|_| Error::Model("runtime init lock poisoned".into()))?;
        if INIT.get().is_none() {
            #[cfg(feature = "dynamic")]
            {
                let embedded = embedded_runtime()?;
                let library = std::env::var_os("ORT_DYLIB_PATH")
                    .map(PathBuf::from)
                    .or(embedded)
                    .or_else(|| {
                        std::env::current_exe()
                            .ok()
                            .and_then(|p| p.parent().map(|p| p.join(runtime_filename())))
                            .filter(|p| p.exists())
                    })
                    .unwrap_or_else(|| PathBuf::from(runtime_filename()));
                let _ = ort::init_from(library)
                    .map_err(failure)?
                    .with_name("QuranRecitationKit")
                    .commit();
            }
            #[cfg(not(feature = "dynamic"))]
            let _ = ort::init().with_name("QuranRecitationKit").commit();
            let _ = INIT.set(());
        }
        let builder = Session::builder()
            .map_err(failure)?
            .with_intra_threads(2)
            .map_err(failure)?;
        #[cfg(all(feature = "coreml", any(target_os = "macos", target_os = "ios")))]
        let builder = builder
            .with_execution_providers([ort::ep::CoreML::default().build()])
            .map_err(failure)?;
        #[cfg(all(feature = "directml", target_os = "windows"))]
        let builder = builder
            .with_parallel_execution(false)
            .map_err(failure)?
            .with_memory_pattern(false)
            .map_err(failure)?
            .with_execution_providers([ort::ep::DirectML::default().build()])
            .map_err(failure)?;
        let mut builder = builder;
        let session = builder
            .commit_from_file(&pack.model_path)
            .map_err(failure)?;
        Ok(Self { session })
    }
}
pub fn runtime_filename() -> &'static str {
    if cfg!(target_os = "windows") {
        "onnxruntime.dll"
    } else if cfg!(target_os = "macos") {
        "libonnxruntime.dylib"
    } else {
        "libonnxruntime.so"
    }
}
impl AcousticModel for OnnxRunner {
    fn infer(&mut self, pcm16k: &[f32]) -> Result<AcousticOutput> {
        if pcm16k.is_empty() || pcm16k.len() > 192000 || pcm16k.iter().any(|x| !x.is_finite()) {
            return Err(Error::Invalid(
                "audio must be finite mono 16 kHz, at most 12 seconds".into(),
            ));
        }
        let waveform = Tensor::from_array(([1, pcm16k.len()], pcm16k.to_vec())).map_err(failure)?;
        let length = Tensor::from_array(([1], vec![pcm16k.len() as i64])).map_err(failure)?;
        let outputs = self
            .session
            .run(ort::inputs!["audio_signal"=>waveform,"length"=>length])
            .map_err(failure)?;
        let (shape, logits) = outputs["log_probs"]
            .try_extract_tensor::<f32>()
            .map_err(failure)?;
        if shape.len() != 3
            || shape[0] != 1
            || shape[2] != 1025
            || shape[1] <= 0
            || logits.iter().any(|x| !x.is_finite())
        {
            return Err(Error::Model("invalid acoustic output shape/values".into()));
        }
        Ok(AcousticOutput {
            logits: logits.to_vec(),
            time: shape[1] as usize,
            vocab: 1025,
        })
    }
}
pub struct Recognizer {
    inner: qrk_core::Recognizer<OnnxRunner>,
}
impl Recognizer {
    pub fn new(model: ModelPack, corpus: Arc<CorpusIndex>, cfg: Config) -> Result<Self> {
        Ok(Self {
            inner: qrk_core::Recognizer::new(OnnxRunner::new(&model)?, corpus, cfg)?,
        })
    }
    pub fn set_expected(&mut self, target: Target) -> Result<()> {
        self.inner.set_expected(target)
    }
    pub fn feed(&mut self, pcm: &[f32]) -> Vec<Event> {
        self.inner.feed(pcm)
    }
    pub fn stop(&mut self) -> Result<Summary> {
        self.inner.stop()
    }
    pub fn reset(&mut self) {
        self.inner.reset()
    }
}
pub struct Spotter {
    inner: qrk_core::Spotter<OnnxRunner>,
}
impl Spotter {
    pub fn new(
        model: ModelPack,
        corpus: Arc<CorpusIndex>,
        config: qrk_core::SpotConfig,
    ) -> Result<Self> {
        Ok(Self {
            inner: qrk_core::Spotter::with_index(
                OnnxRunner::new(&model)?,
                load_spot_index(corpus)?,
                config,
            )?,
        })
    }
    pub fn feed(&mut self, pcm: &[f32]) -> Result<Vec<Event>> {
        self.inner.feed(pcm)
    }
    pub fn stop(&mut self) -> Result<Summary> {
        self.inner.stop()
    }
    pub fn reset(&mut self) {
        self.inner.reset();
    }
}
impl Recognizer {
    pub fn new_spotting(
        model: ModelPack,
        corpus: Arc<CorpusIndex>,
        config: qrk_core::SpotConfig,
    ) -> Result<Spotter> {
        Spotter::new(model, corpus, config)
    }
}
pub fn load_spot_index(corpus: Arc<CorpusIndex>) -> Result<Arc<qrk_core::SpotIndex>> {
    type Cache = std::collections::HashMap<String, std::sync::Weak<qrk_core::SpotIndex>>;
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    let shared = CACHE.get_or_init(|| Mutex::new(Cache::new()));
    if let Some(value) = shared
        .lock()
        .map_err(failure)?
        .get(&corpus.cache_key)
        .and_then(std::sync::Weak::upgrade)
    {
        return Ok(value);
    }
    let digest = hex::encode(Sha256::digest(corpus.cache_key.as_bytes()));
    let directory = cache_directory()?.join("indices");
    let path = directory.join(format!("spot-v1-{digest}.json"));
    let existing = fs::File::open(&path).ok().and_then(|f| {
        let mut b = Vec::new();
        f.take(64 * 1024 * 1024 + 1).read_to_end(&mut b).ok()?;
        qrk_core::SpotIndex::from_cache(corpus.clone(), &b).ok()
    });
    let rebuild = existing.is_none();
    let index = Arc::new(existing.unwrap_or_else(|| qrk_core::SpotIndex::new(corpus.clone())));
    if rebuild && fs::create_dir_all(&directory).is_ok() {
        if let Ok(bytes) = index.cache_bytes() {
            let temp = directory.join(format!(
                ".spot-{}-{}.tmp",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            ));
            if fs::write(&temp, bytes).is_ok()
                && fs::rename(&temp, &path).is_err()
                && cfg!(windows)
                && fs::remove_file(&path).is_ok()
            {
                // Windows cannot replace a rebuildable cache with rename.
                let _ = fs::rename(&temp, &path);
            }
            let _ = fs::remove_file(temp);
        }
    }
    let mut cache = shared.lock().map_err(failure)?;
    cache.retain(|_, weak| weak.strong_count() > 0);
    cache.insert(corpus.cache_key.clone(), Arc::downgrade(&index));
    Ok(index)
}
pub fn match_text(segment: &str) -> Result<qrk_core::TextMatch> {
    static INDEX: OnceLock<Arc<qrk_core::SpotIndex>> = OnceLock::new();
    let index = if let Some(index) = INDEX.get() {
        index.clone()
    } else {
        let value = load_spot_index(load_corpus(None)?)?;
        let _ = INDEX.set(value.clone());
        value
    };
    index.match_text(segment, &qrk_core::SpotConfig::default())
}
#[cfg(feature = "dynamic")]
fn embedded_runtime() -> Result<Option<PathBuf>> {
    let Some(bytes) = EMBEDDED_RUNTIME else {
        return Ok(None);
    };
    let sha = hex::encode(Sha256::digest(bytes));
    let directory = cache_directory()?.join("runtimes").join(&sha);
    let library = directory.join(runtime_filename());
    if validate_file(&library, bytes.len() as u64, &sha).is_ok() {
        return Ok(Some(library));
    }
    fs::create_dir_all(&directory).map_err(failure)?;
    let temporary = directory.join(format!(".runtime-{}.tmp", std::process::id()));
    fs::write(&temporary, bytes).map_err(failure)?;
    validate_file(&temporary, bytes.len() as u64, &sha)?;
    if library.exists() {
        fs::remove_file(&library).map_err(failure)?;
    }
    fs::rename(&temporary, &library).map_err(failure)?;
    Ok(Some(library))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn corrupt_file() {
        let p = std::env::temp_dir().join(format!("qrk-integrity-{}", std::process::id()));
        fs::write(&p, b"test").unwrap();
        assert!(validate_file(&p, 4, &"0".repeat(64)).is_err());
        let _ = fs::remove_file(p);
    }
    #[test]
    fn opt_in_onnx() {
        let Ok(path) = std::env::var("QRK_MODEL_DIR") else {
            eprintln!("SKIP QRK_MODEL_DIR unset");
            return;
        };
        let pack = ModelPack::from_directory(path).unwrap();
        let mut runner = OnnxRunner::new(&pack).unwrap();
        let output = runner
            .infer(
                &(0..32000)
                    .map(|i| (i as f32 * 0.0864).sin() * 0.02)
                    .collect::<Vec<_>>(),
            )
            .unwrap();
        assert_eq!(output.vocab, 1025);
        assert_eq!(output.logits.len(), output.time * 1025);
    }
}
