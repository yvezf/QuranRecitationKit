//! C ABI. Handles own their model/session. JSON callbacks borrow strings only for the callback duration.
#![allow(non_camel_case_types)]
use qrk_core::{Config, Error, Target};
use qrk_onnx::{load_corpus, ModelPack, Recognizer};
use std::{
    cell::RefCell,
    ffi::{c_char, c_void, CStr, CString},
    panic::{catch_unwind, AssertUnwindSafe},
    path::Path,
    sync::Mutex,
};
pub type qrk_status = i32;
pub const QRK_OK: qrk_status = 0;
pub const QRK_INVALID_ARGUMENT: qrk_status = 1;
pub const QRK_ERROR: qrk_status = 2;
pub const QRK_PANIC: qrk_status = 3;
pub type qrk_event_cb = Option<unsafe extern "C" fn(json: *const c_char, user: *mut c_void)>;
pub type qrk_progress_cb = Option<unsafe extern "C" fn(progress: f64, user: *mut c_void)>;
pub struct QrkRecognizer {
    inner: Mutex<Recognizer>,
}
thread_local! {static LAST_ERROR:RefCell<CString>=RefCell::new(CString::new("").unwrap());}
fn status(action: impl FnOnce() -> qrk_core::Result<()>) -> qrk_status {
    match catch_unwind(AssertUnwindSafe(action)) {
        Ok(Ok(())) => {
            set_error("");
            QRK_OK
        }
        Ok(Err(e)) => {
            set_error(&e.to_string());
            if matches!(e, Error::Invalid(_)) {
                QRK_INVALID_ARGUMENT
            } else {
                QRK_ERROR
            }
        }
        Err(_) => {
            set_error("unexpected engine panic");
            QRK_PANIC
        }
    }
}
fn set_error(s: &str) {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = CString::new(s.replace('\0', " ")).unwrap());
}
unsafe fn required<'a>(s: *const c_char) -> qrk_core::Result<&'a str> {
    if s.is_null() {
        return Err(Error::Invalid("null string".into()));
    }
    CStr::from_ptr(s)
        .to_str()
        .map_err(|e| Error::Invalid(e.to_string()))
}
unsafe fn optional<'a>(s: *const c_char) -> qrk_core::Result<Option<&'a str>> {
    if s.is_null() {
        Ok(None)
    } else {
        required(s).map(Some)
    }
}
/// Last error on this thread. Borrowed; never pass it to qrk_string_free.
#[no_mangle]
pub extern "C" fn qrk_last_error() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ptr())
}
/// Static UTF-8 version string; do not free.
#[no_mangle]
pub extern "C" fn qrk_version() -> *const c_char {
    c"0.1.0".as_ptr()
}
/// Owned UTF-8 JSON describing the pinned model and configured release URL. Free with qrk_string_free.
#[no_mangle]
pub extern "C" fn qrk_model_source_json() -> *mut c_char {
    CString::new(serde_json::json!({
        "url":qrk_onnx::model_source_url(),
        "model_release":qrk_onnx::MODEL_RELEASE,
        "cache_directory":qrk_onnx::cache_directory().join(qrk_onnx::MODEL_RELEASE).to_string_lossy(),
        "configured":!qrk_onnx::REPOSITORY_OWNER.starts_with('<'),
        "sha256":qrk_onnx::MODEL_SHA256,"byte_count":qrk_onnx::MODEL_BYTES,
        "manifest":serde_json::from_str::<serde_json::Value>(qrk_onnx::MODEL_MANIFEST).unwrap()
    }).to_string()).unwrap().into_raw()
}
/// Owned UTF-8 platform cache directory. Free with qrk_string_free.
#[no_mangle]
pub extern "C" fn qrk_cache_directory() -> *mut c_char {
    CString::new(qrk_onnx::cache_directory().to_string_lossy().as_ref())
        .unwrap()
        .into_raw()
}
/// Verbatim, attributed Arabic corpus for host display. No normalized index. Free with qrk_string_free.
#[no_mangle]
pub extern "C" fn qrk_corpus_json() -> *mut c_char {
    CString::new(include_str!("../../../corpus/quran-uthmani.json"))
        .unwrap()
        .into_raw()
}
/// Create a handle. The caller owns it and calls qrk_free once.
/// # Safety
/// Non-null strings must be NUL-terminated UTF-8; out must point to writable pointer storage.
#[no_mangle]
pub unsafe extern "C" fn qrk_recognizer_new(
    model_dir: *const c_char,
    corpus_path: *const c_char,
    config_json: *const c_char,
    out: *mut *mut QrkRecognizer,
) -> qrk_status {
    status(|| {
        if out.is_null() {
            return Err(Error::Invalid("null output handle".into()));
        }
        *out = std::ptr::null_mut();
        let model = ModelPack::from_directory(required(model_dir)?)?;
        let corpus = load_corpus(optional(corpus_path)?.map(Path::new))?;
        let config = optional(config_json)?
            .filter(|s| !s.is_empty())
            .map(serde_json::from_str::<Config>)
            .transpose()
            .map_err(|e| Error::Invalid(e.to_string()))?
            .unwrap_or_default();
        let recognizer = Recognizer::new(model, corpus, config)?;
        *out = Box::into_raw(Box::new(QrkRecognizer {
            inner: Mutex::new(recognizer),
        }));
        Ok(())
    })
}
/// # Safety
/// h must be a live handle; target_json must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn qrk_set_expected(
    h: *mut QrkRecognizer,
    target_json: *const c_char,
) -> qrk_status {
    status(|| {
        let h = h
            .as_ref()
            .ok_or_else(|| Error::Invalid("null handle".into()))?;
        let target = Target::from_json(required(target_json)?)?;
        h.inner
            .lock()
            .map_err(|_| Error::Model("session lock poisoned".into()))?
            .set_expected(target)
    })
}
/// Callbacks run synchronously after releasing the session lock. Strings are borrowed until callback return.
/// # Safety
/// h must be live; pcm points to n readable f32 samples (null is permitted only for n=0).
/// The callback and user context must remain valid throughout the call. Do not free h concurrently.
#[no_mangle]
pub unsafe extern "C" fn qrk_feed(
    h: *mut QrkRecognizer,
    pcm: *const f32,
    n: usize,
    callback: qrk_event_cb,
    user: *mut c_void,
) -> qrk_status {
    status(|| {
        let h = h
            .as_ref()
            .ok_or_else(|| Error::Invalid("null handle".into()))?;
        if (pcm.is_null() && n != 0) || n > 16_000 * 60 {
            return Err(Error::Invalid(
                "invalid PCM pointer/count (maximum 60 seconds per FFI call)".into(),
            ));
        }
        let samples = if n == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(pcm, n)
        };
        let events = h
            .inner
            .lock()
            .map_err(|_| Error::Model("session lock poisoned".into()))?
            .feed(samples);
        if let Some(callback) = callback {
            for event in events {
                let json = CString::new(
                    serde_json::to_string(&event).map_err(|e| Error::Invalid(e.to_string()))?,
                )
                .unwrap();
                callback(json.as_ptr(), user);
            }
        }
        Ok(())
    })
}
/// Return the JSON summary, including final events; free the string with qrk_string_free.
/// # Safety
/// h is live; summary_json is writable pointer storage. Do not free h concurrently.
#[no_mangle]
pub unsafe extern "C" fn qrk_stop(
    h: *mut QrkRecognizer,
    summary_json: *mut *mut c_char,
) -> qrk_status {
    status(|| {
        if summary_json.is_null() {
            return Err(Error::Invalid("null summary pointer".into()));
        }
        *summary_json = std::ptr::null_mut();
        let h = h
            .as_ref()
            .ok_or_else(|| Error::Invalid("null handle".into()))?;
        let summary = h
            .inner
            .lock()
            .map_err(|_| Error::Model("session lock poisoned".into()))?
            .stop()?;
        *summary_json = CString::new(
            serde_json::to_string(&summary).map_err(|e| Error::Invalid(e.to_string()))?,
        )
        .unwrap()
        .into_raw();
        Ok(())
    })
}
/// # Safety
/// h must be a live handle, not concurrently freed.
#[no_mangle]
pub unsafe extern "C" fn qrk_reset(h: *mut QrkRecognizer) -> qrk_status {
    status(|| {
        let h = h
            .as_ref()
            .ok_or_else(|| Error::Invalid("null handle".into()))?;
        h.inner
            .lock()
            .map_err(|_| Error::Model("session lock poisoned".into()))?
            .reset();
        Ok(())
    })
}
/// Null is harmless. Free a live handle exactly once, after all calls finish.
/// # Safety
/// h is null or was returned by qrk_recognizer_new and has not been freed.
#[no_mangle]
pub unsafe extern "C" fn qrk_free(h: *mut QrkRecognizer) {
    if !h.is_null() {
        drop(Box::from_raw(h));
    }
}
/// # Safety
/// s is null or an owned string returned by qrk_stop, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn qrk_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
/// Download and verify the configured release model. Optional progress callback runs on this thread.
/// # Safety
/// cache_dir is null or NUL-terminated UTF-8; callback/context remain valid through the call.
#[no_mangle]
pub unsafe extern "C" fn qrk_model_fetch(
    cache_dir: *const c_char,
    callback: qrk_progress_cb,
    user: *mut c_void,
) -> qrk_status {
    status(|| {
        ModelPack::fetch(optional(cache_dir)?.map(Path::new), |fraction| {
            if let Some(callback) = callback {
                callback(fraction, user)
            }
        })?;
        Ok(())
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bindings_receive_one_consistent_model_descriptor() {
        let pointer = qrk_model_source_json();
        let source: serde_json::Value = unsafe {
            let text = CStr::from_ptr(pointer).to_str().unwrap();
            let value = serde_json::from_str(text).unwrap();
            qrk_string_free(pointer);
            value
        };
        assert_eq!(source["url"], qrk_onnx::model_source_url());
        assert_eq!(source["model_release"], qrk_onnx::MODEL_RELEASE);
        assert_eq!(source["sha256"], qrk_onnx::MODEL_SHA256);
        assert_eq!(source["byte_count"], qrk_onnx::MODEL_BYTES);
        assert_eq!(
            source["manifest"]["model"]["sha256"],
            qrk_onnx::MODEL_SHA256
        );
        let cache = qrk_onnx::cache_directory().join(qrk_onnx::MODEL_RELEASE);
        assert_eq!(source["cache_directory"], cache.to_string_lossy().as_ref());
    }
    #[test]
    fn null_arguments_do_not_panic() {
        unsafe {
            assert_eq!(
                qrk_set_expected(std::ptr::null_mut(), std::ptr::null()),
                QRK_INVALID_ARGUMENT
            );
            assert_eq!(
                qrk_stop(std::ptr::null_mut(), std::ptr::null_mut()),
                QRK_INVALID_ARGUMENT
            );
            qrk_free(std::ptr::null_mut());
            qrk_string_free(std::ptr::null_mut());
        }
    }
}
