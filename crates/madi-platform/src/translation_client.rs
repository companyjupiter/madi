//! Native TranslateEngine adapter. The session owns one DnaBroker and routes
//! its events to every client; this adapter never starts a second supervisor.
use crate::dna_broker::{CaptionLease, ClientId, DnaBroker, Event, Launch, RequestId, StopReason};
use madi_core::{
    transcript::Uuid,
    translation::{
        Kind,
        client::{Client, Configuration, Effect, Request},
    },
};
use std::{
    collections::{BTreeMap, VecDeque},
    io,
};
use tokio::time::Instant;

#[derive(Default, Debug)]
pub struct Update {
    /// Semantic events only; Submit effects are consumed here, never sent to UI.
    pub events: Vec<Effect>,
    pub fault: Option<String>,
}
pub struct TranslationClient {
    lease: CaptionLease,
    generation: u64,
    state: Client,
    requests: Vec<(RequestId, u64)>,
    epoch: Instant,
}
impl TranslationClient {
    pub async fn attach(
        broker: &DnaBroker,
        launch: Launch,
        configuration: Configuration,
    ) -> io::Result<Self> {
        let epoch = Instant::now();
        let lease = broker.attach_caption(launch).await?;
        Ok(Self {
            generation: lease.generation,
            lease,
            state: Client::new(configuration, std::time::Duration::ZERO),
            requests: Vec::new(),
            epoch,
        })
    }
    pub fn id(&self) -> ClientId {
        self.lease.client
    }
    pub fn configuration_mut(&mut self) -> &mut Configuration {
        &mut self.state.configuration
    }
    pub fn depth(&self) -> usize {
        self.state.depth()
    }
    pub fn runaway_truncations(&self) -> usize {
        self.state.runaway_truncations()
    }
    pub async fn translate(
        &mut self,
        broker: &DnaBroker,
        text: &str,
        targets: &[String],
        id: Uuid,
        kind: Kind,
        forced: &BTreeMap<String, String>,
    ) -> (bool, Update) {
        let accepted = self.state.translate(
            text,
            targets,
            id,
            kind,
            forced,
            self.epoch.elapsed().as_secs_f64(),
        );
        (accepted, self.execute(broker).await)
    }
    pub async fn handle(&mut self, broker: &DnaBroker, event: &Event) -> Update {
        match event {
            Event::Started { generation, .. } if *generation >= self.generation => {
                self.generation = *generation
            }
            Event::Ready {
                client,
                generation,
                capabilities,
            } if *client == self.id() && *generation >= self.generation => {
                self.generation = *generation;
                self.state.ready(*generation, capabilities.contains("fp"));
            }
            Event::Partial {
                client,
                request,
                generation,
                text,
            } if *client == self.id() => {
                if let Some((_, ticket)) = self.requests.iter().find(|(id, _)| id == request) {
                    self.state
                        .partial(*ticket, *generation, text, self.epoch.elapsed());
                }
            }
            Event::Completed {
                client,
                request,
                text,
            } if *client == self.id() => {
                if let Some(index) = self.requests.iter().position(|(id, _)| id == request) {
                    let (_, ticket) = self.requests.remove(index);
                    self.state.complete(ticket, text.as_deref());
                }
            }
            Event::TimedOut { generation, .. } if *generation == self.generation => {
                self.state.suspend(*generation)
            }
            Event::Stopped {
                generation,
                reason: StopReason::Timeout,
                ..
            } if *generation == self.generation => self.state.suspend(*generation),
            Event::Stopped { generation, .. } if *generation == self.generation => {
                self.state.fail();
                self.requests.clear();
            }
            Event::Unavailable { generation, .. } if *generation == self.generation => {
                self.state.fail();
                self.requests.clear();
            }
            _ => {}
        }
        self.execute(broker).await
    }
    pub async fn stop(&mut self, broker: &DnaBroker) -> io::Result<Update> {
        self.state.stop();
        self.requests.clear();
        let update = self.execute(broker).await;
        self.lease.detach().await?;
        Ok(update)
    }
    async fn execute(&mut self, broker: &DnaBroker) -> Update {
        let mut update = Update::default();
        let mut effects: VecDeque<_> = self.state.take_effects().into();
        let mut transport_failed = false;
        while let Some(effect) = effects.pop_front() {
            match effect {
                Effect::Submit {
                    ticket,
                    request,
                    priority,
                } => {
                    if transport_failed {
                        continue;
                    }
                    let request = match request {
                        Request::Prefix { slot, text } => {
                            crate::dna_broker::Request::Prefix { slot, text }
                        }
                        Request::Turn { prompt } => crate::dna_broker::Request::turn(prompt),
                    };
                    match broker.submit(self.id(), request, priority).await {
                        Ok(id) => self.requests.push((id, ticket)),
                        Err(error) => {
                            update.fault = Some(error.to_string());
                            if error.kind() == io::ErrorKind::InvalidInput {
                                self.state.complete(ticket, None);
                            } else {
                                transport_failed = true;
                                self.state.fail();
                                self.requests.clear();
                            }
                            effects.extend(self.state.take_effects());
                        }
                    }
                }
                Effect::Depth { turns, .. } | Effect::Pressure(turns) => {
                    if let Err(error) = broker.report_caption_pressure(turns as i64) {
                        update.fault = Some(error.to_string());
                        if !transport_failed {
                            transport_failed = true;
                            self.state.fail();
                            self.requests.clear();
                            effects.extend(self.state.take_effects());
                        }
                    }
                    update.events.push(effect);
                }
                _ => update.events.push(effect),
            }
        }
        update
    }
}

#[cfg(test)]
mod tests;
