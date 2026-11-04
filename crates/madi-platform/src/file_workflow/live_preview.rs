use super::*;
use crate::capture_pipeline::OwnedWav;
use madi_core::preview::{self, Scheduler, SourceGate};

pub(super) struct LivePreview {
    pub scheduler: Scheduler<OwnedWav>,
    pub segments_pending: usize,
    enabled: bool,
    source: SourceGate,
}
impl LivePreview {
    pub fn new(enabled: bool, language_selected: bool) -> Self {
        let mut scheduler = Scheduler::default();
        if enabled && language_selected {
            scheduler.start();
        }
        Self {
            scheduler,
            enabled,
            segments_pending: 0,
            source: SourceGate::default(),
        }
    }
}
impl Worker {
    pub(super) async fn pump_preview(&mut self) {
        let (Some(preview), Some(run)) = (&mut self.live_preview, self.run) else {
            return;
        };
        // The DNA lane is not connected yet. Once present its admission/aging
        // signal belongs here, after the strict committed-transcript priority.
        preview.scheduler.set_admitted(
            self.state.phase == ViewPhase::Recording
                && preview.segments_pending == 0
                && !self.closing,
        );
        if let Some((wav, offset)) = preview.scheduler.take_ready() {
            let shown = self
                .store
                .displayed_words(offset)
                .into_iter()
                .map(|word| word.text)
                .collect::<Vec<_>>();
            let forced = preview::forced_prefix(&shown, &preview.source.committed_text());
            match self.session.preview(run, wav.clone(), forced.clone()).await {
                Ok(true) => preview.scheduler.submitted(forced),
                Ok(false) => {
                    // Capture/engine events can race this owner. The executor checks
                    // recording phase, language lock and committed backlog again.
                    preview.scheduler.retry((wav, offset));
                }
                Err(error) => {
                    // Preview is best-effort. Keep draining the authoritative
                    // engine fault/completion so committed text is finalized
                    // and archived even when this admission races teardown.
                    eprintln!("live preview admission: {error}");
                    preview.scheduler.stop();
                }
            }
        }
    }
    fn live_partial(&mut self, text: String) {
        if preview::bounded_partial(&text)
            && !personal_vocabulary::canonically_equal(&self.state.partial, &text)
        {
            if let Some(preview) = &mut self.live_preview {
                preview.source.commit(&text);
            }
            self.state.partial = text;
            if self.render.is_none() {
                self.render = Some(Instant::now() + Duration::from_millis(33));
            }
        }
    }
    pub(super) fn preview_event(&mut self, event: &Event) -> bool {
        let Some(preview) = &mut self.live_preview else {
            return false;
        };
        if let Some(text) = preview.scheduler.consume(event) {
            if let Some(text) = text {
                self.live_partial(text);
            }
            return true;
        }
        match event {
            // SessionController consults the current toggle at language lock;
            // toggling after an already-started lane does not stop that lane.
            Event::LanguageDetected(_)
                if self
                    .preferences
                    .as_ref()
                    .map_or(preview.enabled, |preferences| {
                        preferences.snapshot().settings.live_preview_enabled
                    }) =>
            {
                preview.scheduler.start()
            }
            Event::SegmentEnd => {
                preview.segments_pending = preview.segments_pending.saturating_sub(1)
            }
            Event::WordSectionBegin => preview.source.reset(),
            Event::Partial { t0, text } => {
                let shown = preview::trim_by_count(text, self.store.displayed_words(*t0).len());
                self.live_partial(shown);
            }
            _ => (),
        }
        false
    }
}
