//! Offline expected-text recognition. This crate owns no files, network or audio device.
mod continuous;
pub mod corpus;
pub mod ctc;
pub mod session;
pub mod text;
pub mod types;
pub use corpus::{Corpus, CorpusIndex, Verse};
pub use session::{AcousticModel, AcousticOutput, Recognizer};
pub use types::*;
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid input: {0}")]
    Invalid(String),
    #[error("model failed: {0}")]
    Model(String),
    #[error("corpus/tokenizer failed: {0}")]
    Corpus(String),
}
pub type Result<T> = std::result::Result<T, Error>;
