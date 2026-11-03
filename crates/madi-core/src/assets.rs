//! Shipping AssetManifest values and deterministic model-selection policy.
use serde::Serialize;

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteAsset {
    pub name: &'static str,
    pub url: &'static str,
    pub sha256: &'static str,
    pub size_bytes: u64,
    pub approx_runtime_memory_gb: Option<f64>,
}

pub const TRANSCRIPTION: RemoteAsset = RemoteAsset {
    name: "model.q8.safetensors",
    url: "https://huggingface.co/jupitersong/madi-whisper-turbo-v3-q8/resolve/main/model.q8.safetensors",
    sha256: "1014fd3ad4450a2e43e473eebbab485b165fd68cbe932372071d86c522bb5c8e",
    size_bytes: 867_485_320,
    approx_runtime_memory_gb: None,
};
pub const TRANSLATION_4B: RemoteAsset = RemoteAsset {
    name: "DNA3.0-4B.i1-Q4_K_M.gguf",
    url: "https://huggingface.co/mradermacher/DNA3.0-4B-i1-GGUF/resolve/main/DNA3.0-4B.i1-Q4_K_M.gguf",
    sha256: "a00a837a797d95b23c31e2821855e89d6b931b9c80c59d7dd5dd219554590fd8",
    size_bytes: 2_783_447_424,
    approx_runtime_memory_gb: Some(3.2),
};
pub const TRANSLATION_2B: RemoteAsset = RemoteAsset {
    name: "DNA3.0-2B.i1-Q4_K_M.gguf",
    url: "https://huggingface.co/mradermacher/DNA3.0-2B-i1-GGUF/resolve/main/DNA3.0-2B.i1-Q4_K_M.gguf",
    sha256: "9270db053b27f1ec127e37ad7aaec0efa05dc89fbd158f3c4724e33e478da7a3",
    size_bytes: 1_312_165_344,
    approx_runtime_memory_gb: Some(1.5),
};
pub const TRANSLATION_TIER_THRESHOLD: u64 = 12 * (1 << 30);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum TranslationVariant {
    #[serde(rename = "quality4B")]
    Quality4B,
    #[serde(rename = "realtime2B")]
    Realtime2B,
}
impl TranslationVariant {
    pub fn recommended(physical_memory: u64) -> Self {
        if physical_memory < TRANSLATION_TIER_THRESHOLD {
            Self::Realtime2B
        } else {
            Self::Quality4B
        }
    }
    /// Exact MADI_TRANSLATE_MODEL behavior: case-insensitive 2b/4b, no trimming.
    pub fn selected(physical_memory: u64, override_value: Option<&str>) -> Self {
        match override_value.map(str::to_lowercase).as_deref() {
            Some("2b") => Self::Realtime2B,
            Some("4b") => Self::Quality4B,
            _ => Self::recommended(physical_memory),
        }
    }
    pub fn asset(self) -> RemoteAsset {
        match self {
            Self::Quality4B => TRANSLATION_4B,
            Self::Realtime2B => TRANSLATION_2B,
        }
    }
    pub fn engine_name(self) -> &'static str {
        match self {
            Self::Quality4B => "translate-engine-4b",
            Self::Realtime2B => "translate-engine-2b",
        }
    }
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Quality4B => "DNA3.0-4B",
            Self::Realtime2B => "DNA3.0-2B",
        }
    }
}
