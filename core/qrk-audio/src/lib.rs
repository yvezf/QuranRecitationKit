//! Cross-platform capture and band-limited streaming conversion; no recognition policy.
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rubato::{
    Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction,
};
use std::{
    collections::VecDeque,
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc::SyncSender,
        Arc, Mutex,
    },
};
#[derive(Debug, thiserror::Error)]
pub enum AudioError {
    #[error("audio: {0}")]
    Failure(String),
}
pub type Result<T> = std::result::Result<T, AudioError>;
fn error(e: impl std::fmt::Display) -> AudioError {
    AudioError::Failure(e.to_string())
}
pub struct AudioResampler {
    inner: Option<SincFixedIn<f32>>,
    input: VecDeque<f32>,
    delay: usize,
    input_count: usize,
    output_count: usize,
    rate: f64,
}
impl AudioResampler {
    pub fn new(sample_rate: u32) -> Result<Self> {
        if !(8000..=384000).contains(&sample_rate) {
            return Err(error("unsupported sample rate"));
        }
        let inner = if sample_rate == 16000 {
            None
        } else {
            Some(
                SincFixedIn::<f32>::new(
                    16000. / sample_rate as f64,
                    1.0,
                    SincInterpolationParameters {
                        sinc_len: 128,
                        f_cutoff: 0.95,
                        interpolation: SincInterpolationType::Linear,
                        oversampling_factor: 128,
                        window: WindowFunction::BlackmanHarris2,
                    },
                    1024,
                    1,
                )
                .map_err(error)?,
            )
        };
        let delay = inner.as_ref().map_or(0, Resampler::output_delay);
        Ok(Self {
            inner,
            input: VecDeque::new(),
            delay,
            input_count: 0,
            output_count: 0,
            rate: sample_rate as f64,
        })
    }
    pub fn process(&mut self, input: &[f32]) -> Result<Vec<f32>> {
        if input.iter().any(|x| !x.is_finite()) {
            return Err(error("non-finite audio"));
        }
        self.input_count += input.len();
        if self.inner.is_none() {
            self.output_count += input.len();
            return Ok(input.to_vec());
        }
        self.input.extend(input);
        let mut result = Vec::new();
        let inner = self.inner.as_mut().unwrap();
        while self.input.len() >= inner.input_frames_next() {
            let count = inner.input_frames_next();
            let chunk: Vec<_> = self.input.drain(..count).collect();
            let mut output = inner.process(&[chunk], None).map_err(error)?.remove(0);
            let skip = self.delay.min(output.len());
            output.drain(..skip);
            self.delay -= skip;
            result.extend(output);
        }
        self.output_count += result.len();
        Ok(result)
    }
    pub fn finish(&mut self) -> Result<Vec<f32>> {
        let Some(inner) = self.inner.as_mut() else {
            return Ok(vec![]);
        };
        let desired = (self.input_count as f64 * 16000. / self.rate).round() as usize;
        let mut result = vec![];
        while self.output_count + result.len() < desired {
            let n = inner.input_frames_next();
            let mut chunk: Vec<_> = self.input.drain(..self.input.len().min(n)).collect();
            chunk.resize(n, 0.);
            let mut output = inner.process(&[chunk], None).map_err(error)?.remove(0);
            let skip = self.delay.min(output.len());
            output.drain(..skip);
            self.delay -= skip;
            result.extend(output);
        }
        result.truncate(desired.saturating_sub(self.output_count));
        self.output_count += result.len();
        Ok(result)
    }
}
pub fn devices() -> Result<Vec<String>> {
    let host = cpal::default_host();
    host.input_devices()
        .map_err(error)?
        .map(|d| d.name().map_err(error))
        .collect()
}
pub struct Capture {
    _stream: cpal::Stream,
    pub sample_rate: u32,
    pub channels: u16,
    dropped: Arc<AtomicU64>,
    failure: Arc<Mutex<Option<String>>>,
}
impl Capture {
    pub fn start(name: Option<&str>, sender: SyncSender<Vec<f32>>) -> Result<Self> {
        let host = cpal::default_host();
        let device = if let Some(name) = name {
            host.input_devices()
                .map_err(error)?
                .find(|d| d.name().is_ok_and(|n| n == name))
                .ok_or_else(|| error("input device not found"))?
        } else {
            host.default_input_device()
                .ok_or_else(|| error("no default input device"))?
        };
        let config = device.default_input_config().map_err(error)?;
        let rate = config.sample_rate().0;
        let channels = config.channels();
        if channels == 0 {
            return Err(error("input has no channels"));
        }
        let dropped = Arc::new(AtomicU64::new(0));
        let failure = Arc::new(Mutex::new(None));
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => build::<f32>(
                &device,
                &config.into(),
                sender,
                channels,
                dropped.clone(),
                failure.clone(),
            )?,
            cpal::SampleFormat::I16 => build::<i16>(
                &device,
                &config.into(),
                sender,
                channels,
                dropped.clone(),
                failure.clone(),
            )?,
            cpal::SampleFormat::U16 => build::<u16>(
                &device,
                &config.into(),
                sender,
                channels,
                dropped.clone(),
                failure.clone(),
            )?,
            other => return Err(error(format!("unsupported microphone format {other}"))),
        };
        stream.play().map_err(error)?;
        Ok(Self {
            _stream: stream,
            sample_rate: rate,
            channels,
            dropped,
            failure,
        })
    }
    pub fn failure(&self) -> Option<String> {
        self.failure.lock().ok().and_then(|v| v.clone())
    }
    pub fn dropped_chunks(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }
}
fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    sender: SyncSender<Vec<f32>>,
    channels: u16,
    dropped: Arc<AtomicU64>,
    failure: Arc<Mutex<Option<String>>>,
) -> Result<cpal::Stream>
where
    T: cpal::SizedSample + Copy,
    f32: cpal::FromSample<T>,
{
    device
        .build_input_stream(
            config,
            move |data: &[T], _| {
                let mono = data
                    .chunks(channels as usize)
                    .map(|frame| {
                        frame
                            .iter()
                            .map(|x| cpal::Sample::to_sample::<f32>(*x))
                            .sum::<f32>()
                            / channels as f32
                    })
                    .collect();
                if sender.try_send(mono).is_err() {
                    dropped.fetch_add(1, Ordering::Relaxed);
                }
            },
            move |error| {
                if let Ok(mut slot) = failure.lock() {
                    *slot = Some(error.to_string());
                }
            },
            None,
        )
        .map_err(error)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunk_invariant_and_duration() {
        let input: Vec<_> = (0..4800).map(|i| (i as f32 * 0.07).sin()).collect();
        let mut a = AudioResampler::new(48000).unwrap();
        let mut b = AudioResampler::new(48000).unwrap();
        let mut whole = a.process(&input).unwrap();
        whole.extend(a.finish().unwrap());
        let mut split = vec![];
        for chunk in input.chunks(173) {
            split.extend(b.process(chunk).unwrap());
        }
        split.extend(b.finish().unwrap());
        assert_eq!(whole.len(), 1600);
        assert_eq!(whole, split);
    }
    #[test]
    fn mono_passthrough() {
        let mut r = AudioResampler::new(16000).unwrap();
        assert_eq!(r.process(&[1., 0., -1.]).unwrap(), vec![1., 0., -1.]);
    }
}
