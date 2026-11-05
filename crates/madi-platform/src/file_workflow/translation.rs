use super::*;
use crate::{
    dna_broker::{DnaBroker, Event as DnaEvent, Launch},
    model_assets::Locations,
    translation_client::{TranslationClient, Update},
};
use madi_core::{
    assets::TranslationVariant,
    translation::{
        Kind,
        cache::{Faq, Interim},
        client::Configuration as ClientConfiguration,
        committed,
    },
};
mod faq;
#[cfg(test)]
mod tests;

/// Trusted native model locations. No web command accepts an engine/model path.
pub struct Resources {
    pub locations: Locations,
    pub variant: TranslationVariant,
    pub faq_path: Option<PathBuf>,
    #[cfg(test)]
    pub(crate) test_launch: Option<Launch>,
}
impl Resources {
    pub fn new(locations: Locations, variant: TranslationVariant) -> Self {
        Self {
            locations,
            variant,
            faq_path: None,
            #[cfg(test)]
            test_launch: None,
        }
    }
    pub fn with_faq_path(mut self, path: PathBuf) -> Self {
        self.faq_path = Some(path);
        self
    }
    fn launch(&self) -> Option<Launch> {
        #[cfg(test)]
        if let Some(launch) = &self.test_launch {
            return Some(launch.clone());
        }
        let engine = self.locations.translation_engine(self.variant)?;
        let model = self.locations.translation_model(self.variant);
        crate::model_assets::fast_size_matches(&model, self.variant.asset())
            .then(|| Launch::new(engine, model))
    }
}
pub(super) struct Translations {
    pub broker: DnaBroker,
    resources: Option<Resources>,
    client: Option<TranslationClient>,
    pub policy: committed::Session,
    faq: Faq,
    pub interim: Interim,
    pub language_token: Option<i64>,
    pub tail: Option<(Instant, Uuid, u64)>,
    pub idle: Option<Instant>,
    pub finalized: bool,
    pub dna_busy: bool,
    pub preview_tick: Option<Instant>,
    #[cfg(target_os = "macos")]
    pub last_preview_admit: Option<Instant>,
}
impl Translations {
    pub(super) fn reconcile_launch(&self) -> Option<Launch> {
        self.resources.as_ref().and_then(Resources::launch)
    }
    pub fn new(resources: Option<Resources>) -> io::Result<Self> {
        let faq = resources
            .as_ref()
            .and_then(|r| r.faq_path.as_deref())
            .map_or_else(crate::translation_cache::starter_faq, faq::load);
        Ok(Self {
            broker: DnaBroker::new()?,
            resources,
            client: None,
            policy: committed::Session::default(),
            faq,
            interim: Interim::default(),
            language_token: None,
            tail: None,
            idle: None,
            finalized: false,
            dna_busy: false,
            preview_tick: None,
            #[cfg(target_os = "macos")]
            last_preview_admit: None,
        })
    }
}
impl Worker {
    fn translation_targets(&self) -> Vec<String> {
        self.preferences
            .as_ref()
            .map(|p| p.snapshot().setup.translate_targets)
            .unwrap_or_default()
    }
    pub(super) async fn stop_translation(&mut self) {
        if let Some(client) = &mut self.translations.client
            && let Err(error) = client.stop(&self.translations.broker).await
        {
            eprintln!("translation stop: {error}");
        }
        self.translations.client = None;
        self.translations.tail = None;
        self.translations.policy.depth = 0;
        self.translations.policy.queued_lines = 0;
    }
    async fn ensure_translation(&mut self, targets: &[String]) -> bool {
        if targets.is_empty() {
            return false;
        }
        if self.translations.client.is_some() {
            return true;
        }
        let Some(resources) = &self.translations.resources else {
            return false;
        };
        let Some(launch) = resources.launch() else {
            return false;
        };
        let max_pending = match resources.variant {
            TranslationVariant::Realtime2B => 4,
            TranslationVariant::Quality4B => 30,
        };
        let configuration = ClientConfiguration {
            priority_language: targets.iter().min().cloned(),
            max_pending,
            ..ClientConfiguration::default()
        };
        match TranslationClient::attach(&self.translations.broker, launch, configuration).await {
            Ok(client) => {
                self.translations.client = Some(client);
                true
            }
            Err(error) => {
                eprintln!("translation admission: {error}");
                false
            }
        }
    }
    fn translation_update(&mut self, update: Update) {
        if !update.events.is_empty() && self.render.is_none() {
            self.render = Some(Instant::now() + Duration::from_millis(33));
        }
        for event in update.events {
            self.translations.policy.handle(&mut self.store, &event);
        }
        if let Some(error) = update.fault {
            eprintln!("translation transport: {error}");
        }
        self.schedule();
    }
    async fn submit_translations(&mut self, requests: Vec<committed::Request>) {
        if requests.is_empty() {
            return;
        }
        let targets = self.translation_targets();
        if !self.ensure_translation(&targets).await {
            for request in requests {
                self.translations.policy.invalidate(request.id);
            }
            return;
        }
        if self.translations.finalized
            && let Some(client) = &mut self.translations.client
        {
            client.configuration_mut().max_pending = 0;
            client.configuration_mut().shed_secondary_targets_at = 0;
        }
        let mut cache_hit = false;
        for mut request in requests {
            if request.cacheable
                && let Some(cached) = self
                    .translations
                    .faq
                    .lookup(&request.text)
                    .or_else(|| self.translations.interim.get(&request.text))
            {
                self.translations
                    .policy
                    .apply_cached(&mut self.store, &mut request, &cached);
                cache_hit = true;
            }
            if request.targets.is_empty() {
                continue;
            }
            let Some(client) = &mut self.translations.client else {
                break;
            };
            let (accepted, update) = client
                .translate(
                    &self.translations.broker,
                    &request.text,
                    &request.targets,
                    request.id,
                    Kind::Committed,
                    &BTreeMap::new(),
                )
                .await;
            self.translation_update(update);
            if !accepted {
                // A terminal client cannot emit another callback. Close only
                // these rejected source/language keys using the same empty
                // terminal result semantics as a failed in-flight request.
                for language in request.targets {
                    self.translations.policy.handle(
                        &mut self.store,
                        &madi_core::translation::client::Effect::Result(
                            madi_core::translation::client::Translation {
                                id: request.id,
                                language,
                                source: request.text.clone(),
                                text: String::new(),
                            },
                        ),
                    );
                }
                self.schedule();
            }
        }
        if cache_hit {
            self.schedule();
            if self.translations.finalized && self.translations.policy.depth == 0 {
                self.auto_save().await;
            }
        }
    }
    pub(super) async fn translate_stable(&mut self, including_last: bool) {
        let targets = self.translation_targets();
        if targets.is_empty() {
            return;
        }
        let available = self.translations.client.is_some()
            || self
                .translations
                .resources
                .as_ref()
                .is_some_and(|r| r.launch().is_some());
        if including_last && let Some(client) = &mut self.translations.client {
            client.configuration_mut().max_pending = 0;
            client.configuration_mut().shed_secondary_targets_at = 0;
            let jobs = self.translations.policy.backfill(
                &mut self.store,
                &targets,
                self.translations.language_token,
                true,
            );
            self.submit_translations(jobs).await;
        }
        let jobs = self.translations.policy.stable(
            &mut self.store,
            &targets,
            self.translations.language_token,
            &self.state.partial,
            including_last,
            available,
        );
        self.submit_translations(jobs).await;
    }
    pub(super) async fn translate_line(&mut self, id: Uuid, invalidate: bool) {
        let targets = self.translation_targets();
        if targets.is_empty() {
            return;
        }
        let Some(line) = self.store.lines().iter().find(|l| l.id == id).cloned() else {
            return;
        };
        let available = self.translations.client.is_some()
            || self
                .translations
                .resources
                .as_ref()
                .is_some_and(|r| r.launch().is_some());
        if invalidate {
            self.translations.policy.invalidate(id);
        }
        if let Some(job) = self.translations.policy.line(
            &mut self.store,
            &line,
            &targets,
            self.translations.language_token,
            available,
            None,
        ) {
            self.submit_translations(vec![job]).await;
        }
    }
    pub(super) fn arm_translation_tail(&mut self) {
        let Some(preferences) = &self.preferences else {
            return;
        };
        let p = preferences.snapshot();
        if p.setup.translate_targets.is_empty() {
            return;
        }
        let Some(line) = self.store.lines().last() else {
            return;
        };
        if let Ok(delay) = Duration::try_from_secs_f64(p.settings.translate_tail_seconds)
            && let Some(deadline) = Instant::now().checked_add(delay)
        {
            self.translations.tail = Some((
                deadline,
                line.id,
                madi_core::transcript::text_revision(&line.text()),
            ));
        }
    }
    pub(super) async fn translation_tail(&mut self) {
        let Some((_, id, revision)) = self.translations.tail.take() else {
            return;
        };
        if !self.store.lines().last().is_some_and(|line| {
            line.id == id && madi_core::transcript::text_revision(&line.text()) == revision
        }) {
            return;
        }
        if !self.state.partial.is_empty() {
            self.arm_translation_tail();
            return;
        }
        self.apply_stable_passes();
        self.translate_stable(false).await;
        self.translate_line(id, false).await;
    }
    pub(super) async fn translation_idle(&mut self) {
        self.translations.idle = self
            .state
            .live
            .as_ref()
            .filter(|_| self.state.phase.is_busy())
            .map(|_| Instant::now() + Duration::from_secs(5));
        if self.state.phase != ViewPhase::Recording
            || self.translations.client.is_none()
            || self.translations.policy.depth != 0
        {
            return;
        }
        #[cfg(target_os = "macos")]
        if self
            .live_preview
            .as_ref()
            .is_some_and(|p| p.segments_pending > 0)
        {
            return;
        }
        let targets = self.translation_targets();
        let jobs = self.translations.policy.backfill(
            &mut self.store,
            &targets,
            self.translations.language_token,
            false,
        );
        self.submit_translations(jobs).await;
    }
    pub(super) async fn translation_event(&mut self, event: &DnaEvent) {
        if let DnaEvent::CaptionBusy(busy) = event {
            self.translations.dna_busy = *busy;
        }
        if let Some(client) = &mut self.translations.client {
            let update = client.handle(&self.translations.broker, event).await;
            self.translation_update(update);
            // Keep the immediate ASR durability save, then checkpoint the final
            // translations too. Only this session's owned archive is written.
            if self.translations.finalized && self.translations.policy.depth == 0 {
                self.auto_save().await;
                self.publish();
            }
        }
    }
}
