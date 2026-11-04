//! One active executor behind the shared transcript/archive presentation owner.
//! Replacing a mode first joins the old executor; no two engines share a meeting.
use crate::file_session::{self, Configuration, FileSession};
use madi_core::session::Phase;
use madi_protocol::stream::Output;
use std::{io, path::PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunId {
    File(file_session::RunId),
    #[cfg(target_os = "macos")]
    Live(crate::live_session::RunId),
}
pub enum Kind {
    Phase(Phase),
    Output(Output),
    Finished,
    Failed,
    Fault(String),
    #[cfg(target_os = "macos")]
    Live(crate::live_session::UpdateKind),
    Other,
}
pub struct Update {
    pub run: RunId,
    pub kind: Kind,
}
pub enum Driver {
    File(FileSession),
    #[cfg(target_os = "macos")]
    Live(crate::live_session::LiveSession),
}
impl Driver {
    pub fn new(configuration: Configuration) -> io::Result<Self> {
        FileSession::new(configuration).map(Self::File)
    }
    pub async fn start(
        &mut self,
        configuration: &Configuration,
        path: PathBuf,
        settings: crate::asr_config::FileSettings,
    ) -> io::Result<Option<RunId>> {
        #[cfg(target_os = "macos")]
        if matches!(self, Self::Live(_)) {
            self.shutdown().await?;
            *self = Self::new(configuration.clone())?;
        }
        #[cfg(not(target_os = "macos"))]
        let _ = configuration;
        match self {
            Self::File(file) => file
                .start(path, settings)
                .await
                .map(|run| run.map(RunId::File)),
            #[cfg(target_os = "macos")]
            Self::Live(_) => unreachable!("mode replaced above"),
        }
    }
    #[cfg(target_os = "macos")]
    pub async fn start_live(
        &mut self,
        configuration: &Configuration,
        request: crate::live_session::Request,
    ) -> io::Result<Option<RunId>> {
        if matches!(self, Self::File(_)) {
            self.shutdown().await?;
            *self = Self::Live(crate::live_session::LiveSession::new(
                crate::live_session::Configuration {
                    resources: configuration.resources.clone(),
                    scratch_parent: configuration.scratch_parent.clone(),
                },
            )?);
        }
        match self {
            Self::Live(live) => live.start(request).await.map(|run| run.map(RunId::Live)),
            Self::File(_) => unreachable!("mode replaced above"),
        }
    }
    pub async fn reset(&self) -> io::Result<()> {
        match self {
            Self::File(file) => file.reset().await,
            #[cfg(target_os = "macos")]
            Self::Live(live) => live.reset().await,
        }
    }
    pub async fn shutdown(&mut self) -> io::Result<()> {
        match self {
            Self::File(file) => file.shutdown().await,
            #[cfg(target_os = "macos")]
            Self::Live(live) => live.shutdown().await,
        }
    }
    #[cfg(target_os = "macos")]
    pub fn control(&self, run: RunId, command: super::LiveControl) -> io::Result<()> {
        if let (Self::Live(live), RunId::Live(run)) = (self, run) {
            match command {
                super::LiveControl::Pause => live.pause(run),
                super::LiveControl::Resume => live.resume(run),
                super::LiveControl::Stop => live.stop(run),
                super::LiveControl::InputDevice(device) => {
                    live.switch_input(run, crate::audio_devices::capture_id(device.as_deref())?)
                }
                super::LiveControl::CancelCountdown => Ok(()),
            }
        } else {
            Ok(())
        }
    }
    pub async fn next(&mut self) -> Option<Update> {
        match self {
            Self::File(file) => {
                let update = file.next().await?;
                let kind = match update.kind {
                    file_session::UpdateKind::Phase(phase) => Kind::Phase(phase),
                    file_session::UpdateKind::Output(output) => Kind::Output(output),
                    file_session::UpdateKind::Finished => Kind::Finished,
                    file_session::UpdateKind::Failed => Kind::Failed,
                    file_session::UpdateKind::Fault(message) => Kind::Fault(message),
                    file_session::UpdateKind::Capabilities(_) => Kind::Other,
                };
                Some(Update {
                    run: RunId::File(update.run),
                    kind,
                })
            }
            #[cfg(target_os = "macos")]
            Self::Live(live) => {
                use crate::live_session::UpdateKind;
                let update = live.next().await?;
                let kind = match update.kind {
                    UpdateKind::Phase(phase) => Kind::Phase(phase),
                    UpdateKind::Output(output) => Kind::Output(output),
                    UpdateKind::Finished => Kind::Finished,
                    UpdateKind::Failed => Kind::Failed,
                    UpdateKind::Fault(message) => Kind::Fault(message),
                    other => Kind::Live(other),
                };
                Some(Update {
                    run: RunId::Live(update.run),
                    kind,
                })
            }
        }
    }
    #[cfg(target_os = "macos")]
    pub async fn preview(
        &self,
        run: RunId,
        wav: crate::capture_pipeline::OwnedWav,
        forced: String,
    ) -> io::Result<bool> {
        match (self, run) {
            (Self::Live(live), RunId::Live(run)) => live.preview(run, wav, forced).await,
            _ => Ok(false),
        }
    }
}
