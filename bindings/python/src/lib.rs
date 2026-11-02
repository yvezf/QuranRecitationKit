use pyo3::{
    exceptions::{PyRuntimeError, PyValueError},
    prelude::*,
};
use qrk_core::{Config, Target};
use qrk_onnx::{load_corpus, ModelPack, Recognizer};
use std::sync::Mutex;
fn error(e: impl std::fmt::Display) -> PyErr {
    PyRuntimeError::new_err(e.to_string())
}
#[pyclass(name = "NativeRecognizer")]
struct NativeRecognizer {
    inner: Mutex<Recognizer>,
}
#[pymethods]
impl NativeRecognizer {
    #[new]
    #[pyo3(signature = (model_dir, config_json="{}"))]
    fn new(py: Python<'_>, model_dir: String, config_json: &str) -> PyResult<Self> {
        let cfg: Config =
            serde_json::from_str(config_json).map_err(|e| PyValueError::new_err(e.to_string()))?;
        py.allow_threads(move || {
            Ok(Self {
                inner: Mutex::new(
                    Recognizer::new(
                        ModelPack::from_directory(model_dir).map_err(error)?,
                        load_corpus(None).map_err(error)?,
                        cfg,
                    )
                    .map_err(error)?,
                ),
            })
        })
    }
    fn set_expected(&self, py: Python<'_>, target_json: &str) -> PyResult<()> {
        let target =
            Target::from_json(target_json).map_err(|e| PyValueError::new_err(e.to_string()))?;
        py.allow_threads(|| {
            self.inner
                .lock()
                .map_err(error)?
                .set_expected(target)
                .map_err(error)
        })
    }
    fn feed(&self, py: Python<'_>, pcm16k: Vec<f32>) -> PyResult<String> {
        if pcm16k.len() > 960_000 || pcm16k.iter().any(|x| !x.is_finite()) {
            return Err(PyValueError::new_err(
                "feed expects at most 60 seconds of finite mono 16 kHz samples",
            ));
        }
        py.allow_threads(|| {
            serde_json::to_string(&self.inner.lock().map_err(error)?.feed(&pcm16k)).map_err(error)
        })
    }
    fn stop(&self, py: Python<'_>) -> PyResult<String> {
        py.allow_threads(|| {
            serde_json::to_string(&self.inner.lock().map_err(error)?.stop().map_err(error)?)
                .map_err(error)
        })
    }
    fn reset(&self, py: Python<'_>) -> PyResult<()> {
        py.allow_threads(|| {
            self.inner.lock().map_err(error)?.reset();
            Ok(())
        })
    }
}
#[pyfunction]
fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
#[pyfunction]
#[pyo3(signature=(cache_dir=None))]
fn model_fetch(py: Python<'_>, cache_dir: Option<String>) -> PyResult<String> {
    py.allow_threads(|| {
        ModelPack::fetch(cache_dir.as_deref().map(std::path::Path::new), |_| {})
            .map(|p| {
                p.model_path
                    .parent()
                    .unwrap()
                    .to_string_lossy()
                    .into_owned()
            })
            .map_err(error)
    })
}
#[pymodule]
fn _native(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<NativeRecognizer>()?;
    m.add_function(wrap_pyfunction!(version, m)?)?;
    m.add_function(wrap_pyfunction!(model_fetch, m)?)?;
    Ok(())
}
