use super::*;
use std::io::Read;
use tokio_tungstenite::{
    accept_hdr_async_with_config,
    tungstenite::{
        handshake::server::{ErrorResponse, Request, Response},
        protocol::WebSocketConfig,
        Message,
    },
};
struct Session {
    engine: Option<Engine>,
    resampler: Option<AudioResampler>,
    format: String,
    model: Option<PathBuf>,
    corpus: Option<PathBuf>,
}
impl Session {
    fn new(args: &Args) -> Self {
        Self {
            engine: None,
            resampler: None,
            format: "f32le".into(),
            model: args.model.clone(),
            corpus: args.corpus.clone(),
        }
    }
    fn json(&mut self, message: &str) -> AnyResult<Vec<Value>> {
        let value: Value = serde_json::from_str(message)?;
        match value["type"].as_str() {
            Some("match_text") => {
                let result =
                    qrk_onnx::match_text(value["text"].as_str().ok_or("text must be a string")?)?;
                let mut result = serde_json::to_value(result)?;
                result["type"] = json!("text_match");
                Ok(vec![result])
            }
            Some("start") => {
                if self.engine.is_some() {
                    return Err("session is already started".into());
                }
                let rate = value["sample_rate"].as_u64().unwrap_or(16000);
                if ![16000, 44100, 48000].contains(&rate) {
                    return Err("sample_rate must be 16000, 44100 or 48000".into());
                }
                let format = value["format"].as_str().unwrap_or("f32le");
                if !["f32le", "s16le"].contains(&format) {
                    return Err("format must be f32le or s16le".into());
                }
                let model = if let Some(path) = &self.model {
                    ModelPack::from_directory(path)?
                } else {
                    ModelPack::fetch(None, |_| {})?
                };
                let mode = value["mode"].as_str().unwrap_or("track");
                let corpus = load_corpus(self.corpus.as_deref())?;
                let mut engine = match mode {
                    "track" => {
                        let mut r = Recognizer::new(model, corpus, Config::default())?;
                        r.set_expected(Target::from_json(&value["target"].to_string())?)?;
                        Engine::Tracking(r)
                    }
                    "spot" => {
                        let config = if value.get("configuration").is_some() {
                            serde_json::from_value::<SpotConfig>(value["configuration"].clone())?
                        } else {
                            SpotConfig::default()
                        };
                        Engine::Spot(qrk_onnx::Spotter::new(model, corpus, config)?)
                    }
                    _ => return Err("mode must be track or spot".into()),
                };
                self.resampler = Some(AudioResampler::new(rate as u32)?);
                self.format = format.into();
                let initial = engine.feed(&[])?;
                self.engine = Some(engine);
                Ok(initial
                    .iter()
                    .map(|e| serde_json::to_value(e).unwrap())
                    .collect())
            }
            Some("audio") => {
                use base64::Engine;
                let data = base64::engine::general_purpose::STANDARD
                    .decode(value["data"].as_str().ok_or("audio.data must be base64")?)?;
                self.audio(&data)
            }
            Some("stop") => {
                let mut engine = self.engine.take().ok_or("session has not started")?;
                let tail = self.resampler.take().unwrap().finish()?;
                let mut values: Vec<Value> = engine
                    .feed(&tail)?
                    .iter()
                    .map(|e| serde_json::to_value(e).unwrap())
                    .collect();
                let summary = engine.stop()?;
                values.extend(
                    summary
                        .events
                        .iter()
                        .map(|e| serde_json::to_value(e).unwrap()),
                );
                values.push(json!({"type":"summary","verses":summary.verses,"quotes":summary.quotes,"transcript":summary.transcript,"duration":summary.duration}));
                Ok(values)
            }
            Some("reset") => {
                self.engine = None;
                self.resampler = None;
                Ok(vec![json!({"type":"state","state":"idle"})])
            }
            _ => Err("unknown command type".into()),
        }
    }
    fn audio(&mut self, data: &[u8]) -> AnyResult<Vec<Value>> {
        if data.len() > 1_048_576 {
            return Err("audio frame exceeds 1 MiB".into());
        }
        let engine = self.engine.as_mut().ok_or("send start before audio")?;
        let pcm: Vec<f32> = if self.format == "s16le" {
            if !data.len().is_multiple_of(2) {
                return Err("unaligned s16le frame".into());
            }
            data.as_chunks::<2>()
                .0
                .iter()
                .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.)
                .collect()
        } else {
            if !data.len().is_multiple_of(4) {
                return Err("unaligned f32le frame".into());
            }
            data.as_chunks::<4>()
                .0
                .iter()
                .map(|b| f32::from_le_bytes(*b))
                .collect()
        };
        if pcm.iter().any(|x| !x.is_finite()) {
            return Err("audio contains non-finite samples".into());
        }
        let converted = self.resampler.as_mut().unwrap().process(&pcm)?;
        Ok(engine
            .feed(&converted)?
            .iter()
            .map(|e| serde_json::to_value(e).unwrap())
            .collect())
    }
}
fn error(message: impl std::fmt::Display) -> Vec<Value> {
    vec![json!({"type":"error","message":message.to_string()})]
}
fn authorized(request: &Request, token: Option<&str>) -> bool {
    if let Some(token) = token {
        let expected = format!("Bearer {token}");
        let supplied = request
            .headers()
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        return supplied.len() == expected.len()
            && supplied
                .bytes()
                .zip(expected.bytes())
                .fold(0u8, |v, (a, b)| v | (a ^ b))
                == 0;
    }
    // Native clients have no Origin. Browser pages need an explicit secret.
    request
        .headers()
        .get("origin")
        .is_none_or(|o| o == "null" || o == "file://")
}
// The third-party handshake trait requires an unboxed HTTP error response.
#[allow(clippy::result_large_err)]
pub async fn serve(args: &Args, port: u16, token: Option<&str>, stdio: bool) -> AnyResult<()> {
    if stdio {
        let mut session = Session::new(args);
        let mut input = io::stdin().lock();
        loop {
            let mut line = String::new();
            let bytes = std::io::Read::by_ref(&mut input)
                .take(1_500_000)
                .read_line(&mut line)?;
            if bytes == 0 {
                break;
            }
            let values = if bytes >= 1_500_000 {
                error("command exceeds limit")
            } else {
                session.json(&line).unwrap_or_else(error)
            };
            for value in values {
                println!("{value}");
            }
            io::stdout().flush()?;
            if bytes >= 1_500_000 {
                break;
            }
        }
        return Ok(());
    }
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await?;
    eprintln!("Listening {}", listener.local_addr()?);
    let slots = Arc::new(tokio::sync::Semaphore::new(4));
    loop {
        let (stream, _) = listener.accept().await?;
        let Ok(permit) = slots.clone().try_acquire_owned() else {
            continue;
        };
        let mut session = Session::new(args);
        let token = token.map(str::to_owned);
        tokio::spawn(async move {
            let _permit = permit;
            let config = WebSocketConfig::default()
                .max_message_size(Some(1_048_576))
                .max_frame_size(Some(1_048_576));
            let socket = accept_hdr_async_with_config(
                stream,
                move |request: &Request, response: Response| {
                    if authorized(request, token.as_deref()) {
                        Ok(response)
                    } else {
                        Err({
                            let mut response = ErrorResponse::new(Some("Unauthorized".into()));
                            *response.status_mut() =
                                tokio_tungstenite::tungstenite::http::StatusCode::UNAUTHORIZED;
                            response
                        })
                    }
                },
                Some(config),
            )
            .await;
            let Ok(mut socket) = socket else { return };
            while let Some(Ok(message)) = socket.next().await {
                let values = match message {
                    Message::Text(text) => session.json(&text).unwrap_or_else(error),
                    Message::Binary(data) => session.audio(&data).unwrap_or_else(error),
                    Message::Close(_) => break,
                    Message::Ping(data) => {
                        if socket.send(Message::Pong(data)).await.is_err() {
                            break;
                        }
                        continue;
                    }
                    _ => continue,
                };
                for value in values {
                    if socket
                        .send(Message::Text(value.to_string().into()))
                        .await
                        .is_err()
                    {
                        return;
                    }
                }
            }
        });
    }
}
