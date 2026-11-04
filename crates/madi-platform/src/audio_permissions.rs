//! Pre-countdown permission contract from SessionController. A cancelled native
//! request never advances to another permission or starts capture.
use madi_core::{preferences::UILanguage, setup::AudioSource};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    OpenSettings,
    Restart,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Microphone,
    SystemAudio,
}
pub fn required(source: AudioSource) -> &'static [Kind] {
    match source {
        AudioSource::Mic => &[Kind::Microphone],
        AudioSource::System => &[Kind::SystemAudio],
        AudioSource::Both => &[Kind::Microphone, Kind::SystemAudio],
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Issue {
    MicrophoneDenied,
    SystemAudioDenied,
    SystemAudioRestartRequired,
}
impl Issue {
    pub fn message(self, language: UILanguage) -> &'static str {
        match (self, language) {
            (Self::MicrophoneDenied, UILanguage::Ko) => {
                "녹음 전에 마이크 권한이 필요해요. 시스템 설정에서 Madi를 허용한 뒤 다시 시도해주세요."
            }
            (Self::MicrophoneDenied, UILanguage::En) => {
                "Madi needs microphone access before recording. Allow it in System Settings, then try again."
            }
            (Self::MicrophoneDenied, UILanguage::Ja) => {
                "録音前にマイクへのアクセスが必要です。システム設定で Madi を許可してから、もう一度お試しください。"
            }
            (Self::SystemAudioDenied, UILanguage::Ko) => {
                "녹음 전에 시스템 오디오 권한이 필요해요. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 Madi를 허용한 뒤 다시 시작해주세요."
            }
            (Self::SystemAudioDenied, UILanguage::En) => {
                "Madi needs system audio access before recording. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then restart Madi."
            }
            (Self::SystemAudioDenied, UILanguage::Ja) => {
                "録音前にシステムオーディオへのアクセスが必要です。システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオで Madi を許可してから再起動してください。"
            }
            (Self::SystemAudioRestartRequired, UILanguage::Ko) => {
                "시스템 오디오 권한을 허용했어요. 적용을 위해 Madi를 한 번 다시 시작해주세요."
            }
            (Self::SystemAudioRestartRequired, UILanguage::En) => {
                "System audio access is allowed. Restart Madi once to apply it."
            }
            (Self::SystemAudioRestartRequired, UILanguage::Ja) => {
                "システムオーディオのアクセスを許可しました。適用するため Madi を再起動してください。"
            }
        }
    }
}

#[cfg(target_os = "macos")]
mod native {
    use super::*;
    use std::{
        collections::BTreeMap,
        io,
        sync::{
            Mutex, OnceLock,
            atomic::{AtomicU64, Ordering},
        },
    };
    use tokio::sync::oneshot;
    type Reply = oneshot::Sender<io::Result<Option<Issue>>>;
    static PENDING: OnceLock<Mutex<BTreeMap<u64, Reply>>> = OnceLock::new();
    static NEXT: AtomicU64 = AtomicU64::new(1);
    fn pending() -> std::sync::MutexGuard<'static, BTreeMap<u64, Reply>> {
        PENDING
            .get_or_init(Mutex::default)
            .lock()
            .unwrap_or_else(|p| p.into_inner())
    }
    unsafe extern "C" {
        fn madi_audio_permission_request(
            id: u64,
            kind: u32,
            callback: extern "C" fn(u64, u32) -> u8,
        );
    }
    extern "C" fn receive(id: u64, status: u32) -> u8 {
        if status == 4 {
            return pending().contains_key(&id) as u8;
        }
        let Some(reply) = pending().remove(&id) else {
            return 0;
        };
        let result = match status {
            0 => Ok(None),
            1 => Ok(Some(Issue::MicrophoneDenied)),
            2 => Ok(Some(Issue::SystemAudioDenied)),
            3 => Ok(Some(Issue::SystemAudioRestartRequired)),
            _ => Err(io::Error::other("unknown native audio permission result")),
        };
        reply.send(result).is_ok() as u8
    }
    struct Request {
        id: u64,
        result: oneshot::Receiver<io::Result<Option<Issue>>>,
    }
    impl Request {
        fn register() -> io::Result<Self> {
            // compare_exchange retains the workspace's Rust 1.90 MSRV.
            let mut id = NEXT.load(Ordering::Relaxed);
            loop {
                let next = id
                    .checked_add(1)
                    .ok_or_else(|| io::Error::other("audio permission identity exhausted"))?;
                match NEXT.compare_exchange_weak(id, next, Ordering::Relaxed, Ordering::Relaxed) {
                    Ok(_) => break,
                    Err(current) => id = current,
                }
            }
            let (reply, result) = oneshot::channel();
            pending().insert(id, reply);
            Ok(Self { id, result })
        }
        fn start(kind: Kind) -> io::Result<Self> {
            let request = Self::register()?;
            // SAFETY: Swift copies scalar inputs, checks eligibility on main,
            // and borrows no Rust data while the OS permission dialog is open.
            unsafe {
                madi_audio_permission_request(
                    request.id,
                    match kind {
                        Kind::Microphone => 0,
                        Kind::SystemAudio => 1,
                    },
                    receive,
                )
            };
            Ok(request)
        }
        async fn wait(mut self) -> io::Result<Option<Issue>> {
            (&mut self.result)
                .await
                .map_err(|_| io::Error::other("audio permission callback closed"))?
        }
    }
    impl Drop for Request {
        fn drop(&mut self) {
            pending().remove(&self.id);
        }
    }
    pub async fn preflight(source: AudioSource) -> io::Result<Option<Issue>> {
        for kind in required(source) {
            if let Some(issue) = Request::start(*kind)?.wait().await? {
                return Ok(Some(issue));
            }
        }
        Ok(None)
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        #[tokio::test]
        async fn cancelled_permission_callback_cannot_touch_new_request_or_prompt_after_retirement()
        {
            let old = Request::register().unwrap();
            let old_id = old.id;
            assert_eq!(receive(old_id, 4), 1);
            drop(old);
            assert_eq!(receive(old_id, 4), 0);
            let new = Request::register().unwrap();
            let id = new.id;
            assert_ne!(id, old_id);
            assert_eq!(receive(old_id, 0), 0);
            assert_eq!(receive(id, 4), 1);
            assert_eq!(receive(id, 3), 1);
            assert_eq!(receive(id, 0), 0);
            assert_eq!(
                new.wait().await.unwrap(),
                Some(Issue::SystemAudioRestartRequired)
            );
        }
    }
}
#[cfg(target_os = "macos")]
pub use native::preflight;
