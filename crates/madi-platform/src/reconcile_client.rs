//! SummaryEngine's reconcile lane on the session's existing DNA broker.
//! Only the native owner may construct prompts; this is not WebView IPC.
use crate::dna_broker::{ClientId, ClientLease, DnaBroker, Event, Launch, Request, RequestId};
use madi_core::{
    dna::Priority,
    reconcile::{self, Replies},
};
use std::io;

#[derive(Default, Debug)]
pub struct Update {
    pub completed: bool,
    pub text: Option<String>,
    pub fault: Option<String>,
}
pub struct ReconcileClient {
    lease: ClientLease,
    requests: Vec<RequestId>,
    replies: Option<Replies>,
    stopped: bool,
}
impl ReconcileClient {
    pub async fn attach(broker: &DnaBroker, launch: Launch) -> io::Result<Self> {
        Ok(Self {
            lease: broker.attach_owned(launch).await?,
            requests: Vec::new(),
            replies: None,
            stopped: false,
        })
    }
    pub fn id(&self) -> ClientId {
        self.lease.client
    }
    pub fn pending(&self) -> usize {
        self.replies.as_ref().map_or(0, Replies::pending)
    }
    pub async fn reconcile(&mut self, broker: &DnaBroker, numbered: &str) -> io::Result<Update> {
        if self.stopped {
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        if self.replies.is_some() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let batches = reconcile::prompt_batches(numbered, 800);
        if batches.is_empty() {
            return Ok(Update {
                completed: true,
                ..Default::default()
            });
        }
        self.replies = Some(Replies::new(batches.len()));
        let mut update = Update::default();
        for body in batches {
            let request = Request::Turn {
                prompt: format!("{} {body}", reconcile::INSTRUCTION),
                preserve_newlines: true,
            };
            match broker
                .submit(self.id(), request, Priority::PostSession)
                .await
            {
                Ok(request) => self.requests.push(request),
                Err(error) => {
                    update.fault = Some(error.to_string());
                    self.complete(None, &mut update);
                }
            }
        }
        Ok(update)
    }
    fn complete(&mut self, text: Option<&str>, update: &mut Update) {
        if let Some(text) = self.replies.as_mut().and_then(|r| r.complete(text)) {
            self.replies = None;
            update.completed = true;
            update.text = Some(text);
        }
    }
    pub fn handle(&mut self, event: &Event) -> Update {
        let mut update = Update::default();
        if let Event::Completed {
            client,
            request,
            text,
        } = event
            && *client == self.id()
            && let Some(index) = self.requests.iter().position(|id| id == request)
        {
            self.requests.remove(index);
            self.complete(text.as_deref(), &mut update);
        }
        update
    }
    /// Cancel only queued AI turns. The active turn may still finish; nil
    /// completions drain the original batch counter in broker callback order.
    pub async fn cancel_pending(&self, broker: &DnaBroker) -> io::Result<()> {
        broker.cancel_pending(self.id()).await
    }
    pub async fn stop(&mut self) -> io::Result<()> {
        self.stopped = true;
        self.requests.clear();
        self.replies = None;
        self.lease.detach().await
    }
}

#[cfg(test)]
mod tests;
