use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    Surah(u16),
    Ayahs {
        surah: u16,
        from: u16,
        to: u16,
    },
    Words {
        surah: u16,
        ayah: u16,
        from: usize,
        to: usize,
    },
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum WireTarget {
    Surah {
        surah: u16,
    },
    Ayahs {
        surah: u16,
        from: u16,
        to: u16,
    },
    Words {
        surah: u16,
        ayah: u16,
        from: usize,
        to: usize,
    },
}
impl serde::Serialize for Target {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        match *self {
            Self::Surah(surah) => WireTarget::Surah { surah },
            Self::Ayahs { surah, from, to } => WireTarget::Ayahs { surah, from, to },
            Self::Words {
                surah,
                ayah,
                from,
                to,
            } => WireTarget::Words {
                surah,
                ayah,
                from,
                to,
            },
        }
        .serialize(s)
    }
}
impl<'de> serde::Deserialize<'de> for Target {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        Ok(match WireTarget::deserialize(d)? {
            WireTarget::Surah { surah } => Self::Surah(surah),
            WireTarget::Ayahs { surah, from, to } => Self::Ayahs { surah, from, to },
            WireTarget::Words {
                surah,
                ayah,
                from,
                to,
            } => Self::Words {
                surah,
                ayah,
                from,
                to,
            },
        })
    }
}
impl Target {
    pub fn surah(number: u16) -> Self {
        Self::Surah(number)
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Idle,
    Listening,
    Evaluating,
    Ended,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RetryReason {
    Inconclusive,
    OffTarget,
    Noise,
    TooShort,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct VerseMatch {
    pub surah: u16,
    pub ayah: u16,
    pub confidence: f64,
    pub duration_seconds: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    QuoteDetected {
        #[serde(flatten)]
        quote: crate::spot::QuoteDetected,
    },
    WordProgress {
        surah: u16,
        ayah: u16,
        word_index: usize,
        total_words: usize,
        matched_word_indices: Vec<usize>,
        confidence: f64,
    },
    VerseMatch {
        #[serde(flatten)]
        verse: VerseMatch,
    },
    NeedsRetry {
        reason: RetryReason,
    },
    RawTranscript {
        text: String,
        confidence: f64,
    },
    State {
        state: State,
    },
}
#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
pub struct Summary {
    #[serde(rename = "type")]
    pub kind: SummaryType,
    pub verses: Vec<VerseMatch>,
    #[serde(default)]
    pub quotes: Vec<crate::spot::QuoteDetected>,
    pub transcript: String,
    pub duration: f64,
    pub events: Vec<Event>,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum Policy {
    #[default]
    Balanced,
    Conservative,
    Lenient,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub live_tracking: bool,
    pub maximum_window_seconds: f64,
    pub backtrack_words: usize,
    pub lookahead_words: usize,
    pub policy: Policy,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            live_tracking: true,
            maximum_window_seconds: 12.,
            backtrack_words: 3,
            lookahead_words: 32,
            policy: Policy::Balanced,
        }
    }
}
impl Config {
    pub fn validate(&self) -> crate::Result<()> {
        if !self.maximum_window_seconds.is_finite()
            || !(2.0..=12.0).contains(&self.maximum_window_seconds)
            || self.backtrack_words > 32
            || !(1..=128).contains(&self.lookahead_words)
        {
            return Err(crate::Error::Invalid(
                "window configuration is out of range".into(),
            ));
        }
        Ok(())
    }
}
impl Target {
    /// The protocol's compact form {"surah":1} is accepted alongside tagged targets.
    pub fn from_json(json: &str) -> crate::Result<Self> {
        let value: serde_json::Value =
            serde_json::from_str(json).map_err(|e| crate::Error::Invalid(e.to_string()))?;
        if value.get("kind").is_some() {
            return serde_json::from_value(value).map_err(|e| crate::Error::Invalid(e.to_string()));
        }
        let number = |name: &str| {
            value
                .get(name)
                .and_then(serde_json::Value::as_u64)
                .ok_or_else(|| crate::Error::Invalid(format!("target requires {name}")))
        };
        let surah = u16::try_from(number("surah")?)
            .map_err(|_| crate::Error::Invalid("surah out of range".into()))?;
        if value.get("ayah").is_some() {
            Ok(Self::Words {
                surah,
                ayah: u16::try_from(number("ayah")?)
                    .map_err(|_| crate::Error::Invalid("ayah out of range".into()))?,
                from: number("from")? as usize,
                to: number("to")? as usize,
            })
        } else if value.get("from").is_some() || value.get("to").is_some() {
            Ok(Self::Ayahs {
                surah,
                from: u16::try_from(number("from")?)
                    .map_err(|_| crate::Error::Invalid("ayah out of range".into()))?,
                to: u16::try_from(number("to")?)
                    .map_err(|_| crate::Error::Invalid("ayah out of range".into()))?,
            })
        } else {
            Ok(Self::Surah(surah))
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum SummaryType {
    #[default]
    Summary,
}
