use napi::{bindgen_prelude::*, Env, Task};
use napi_derive::napi;
use qrk_core::{Config, Target};
use qrk_onnx::{load_corpus, ModelPack, Recognizer};
use std::{
    path::Path,
    sync::{Arc, Mutex},
};
fn error(e: impl std::fmt::Display) -> napi::Error {
    napi::Error::from_reason(e.to_string())
}
#[napi]
pub struct NativeRecognizer {
    inner: Arc<Mutex<Recognizer>>,
}
#[napi]
impl NativeRecognizer {
    #[napi(constructor)]
    pub fn new(
        model_dir: String,
        corpus_path: Option<String>,
        config_json: Option<String>,
    ) -> Result<Self> {
        let model = ModelPack::from_directory(model_dir).map_err(error)?;
        let corpus = load_corpus(corpus_path.as_deref().map(Path::new)).map_err(error)?;
        let config = config_json
            .map(|s| serde_json::from_str::<Config>(&s))
            .transpose()
            .map_err(error)?
            .unwrap_or_default();
        Ok(Self {
            inner: Arc::new(Mutex::new(
                Recognizer::new(model, corpus, config).map_err(error)?,
            )),
        })
    }
    #[napi]
    pub fn set_expected(&self, target: String) -> Result<()> {
        self.inner
            .lock()
            .map_err(error)?
            .set_expected(Target::from_json(&target).map_err(error)?)
            .map_err(error)
    }
    #[napi]
    pub fn feed(&self, pcm: Float32Array) -> AsyncTask<FeedTask> {
        AsyncTask::new(FeedTask {
            inner: self.inner.clone(),
            pcm: pcm.to_vec(),
            stop: false,
        })
    }
    #[napi]
    pub fn stop(&self) -> AsyncTask<FeedTask> {
        AsyncTask::new(FeedTask {
            inner: self.inner.clone(),
            pcm: vec![],
            stop: true,
        })
    }
    #[napi]
    pub fn reset(&self) -> Result<()> {
        self.inner.lock().map_err(error)?.reset();
        Ok(())
    }
}
pub struct FeedTask {
    inner: Arc<Mutex<Recognizer>>,
    pcm: Vec<f32>,
    stop: bool,
}
impl Task for FeedTask {
    type Output = String;
    type JsValue = String;
    fn compute(&mut self) -> Result<String> {
        let mut engine = self.inner.lock().map_err(error)?;
        if self.stop {
            serde_json::to_string(&engine.stop().map_err(error)?).map_err(error)
        } else {
            serde_json::to_string(&engine.feed(&self.pcm)).map_err(error)
        }
    }
    fn resolve(&mut self, _: Env, output: String) -> Result<String> {
        Ok(output)
    }
}
#[napi]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").into()
}

#[napi]
pub struct NativeSpotter {
    inner: Arc<Mutex<qrk_onnx::Spotter>>,
}
#[napi]
impl NativeSpotter {
    #[napi(constructor)]
    pub fn new(
        model_dir: String,
        corpus_path: Option<String>,
        config_json: Option<String>,
    ) -> Result<Self> {
        let config = config_json
            .map(|s| serde_json::from_str::<qrk_core::SpotConfig>(&s))
            .transpose()
            .map_err(error)?
            .unwrap_or_default();
        Ok(Self {
            inner: Arc::new(Mutex::new(
                qrk_onnx::Spotter::new(
                    ModelPack::from_directory(model_dir).map_err(error)?,
                    load_corpus(corpus_path.as_deref().map(Path::new)).map_err(error)?,
                    config,
                )
                .map_err(error)?,
            )),
        })
    }
    #[napi]
    pub fn feed(&self, pcm: Float32Array) -> AsyncTask<SpotTask> {
        AsyncTask::new(SpotTask {
            inner: self.inner.clone(),
            pcm: pcm.to_vec(),
            stop: false,
        })
    }
    #[napi]
    pub fn stop(&self) -> AsyncTask<SpotTask> {
        AsyncTask::new(SpotTask {
            inner: self.inner.clone(),
            pcm: vec![],
            stop: true,
        })
    }
    #[napi]
    pub fn reset(&self) -> Result<()> {
        self.inner.lock().map_err(error)?.reset();
        Ok(())
    }
}
pub struct SpotTask {
    inner: Arc<Mutex<qrk_onnx::Spotter>>,
    pcm: Vec<f32>,
    stop: bool,
}
impl Task for SpotTask {
    type Output = String;
    type JsValue = String;
    fn compute(&mut self) -> Result<String> {
        let mut engine = self.inner.lock().map_err(error)?;
        if self.stop {
            serde_json::to_string(&engine.stop().map_err(error)?).map_err(error)
        } else {
            serde_json::to_string(&engine.feed(&self.pcm).map_err(error)?).map_err(error)
        }
    }
    fn resolve(&mut self, _: Env, result: String) -> Result<String> {
        Ok(result)
    }
}
pub struct TextTask {
    segment: String,
}
impl Task for TextTask {
    type Output = String;
    type JsValue = String;
    fn compute(&mut self) -> Result<String> {
        serde_json::to_string(&qrk_onnx::match_text(&self.segment).map_err(error)?).map_err(error)
    }
    fn resolve(&mut self, _: Env, result: String) -> Result<String> {
        Ok(result)
    }
}
#[napi]
pub fn match_text(segment: String) -> AsyncTask<TextTask> {
    AsyncTask::new(TextTask { segment })
}
