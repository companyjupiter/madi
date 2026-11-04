//! SessionController's W1 committed-segment coverage rule. Preview output never
//! enters this owner. Audio ownership/transport and lifecycle are native concerns.
use serde::Serialize;
use std::collections::VecDeque;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Job<T> {
    pub offset: f64,
    pub audio: T,
    pub had_speech: bool,
    pub retried: bool,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Coverage<T> {
    queue: VecDeque<Job<T>>,
    words_since_segment: usize,
    pub gaps: Vec<f64>,
}
impl<T> Default for Coverage<T> {
    fn default() -> Self {
        Self {
            queue: VecDeque::new(),
            words_since_segment: 0,
            gaps: vec![],
        }
    }
}
impl<T: Clone> Coverage<T> {
    pub fn pending(&self) -> usize {
        self.queue.len()
    }
    pub fn feed(&mut self, offset: f64, audio: T, had_speech: bool) {
        self.queue.push_back(Job {
            offset,
            audio,
            had_speech,
            retried: false,
        });
    }
    pub fn word(&mut self) {
        self.words_since_segment += 1;
    }
    pub fn segment_end(&mut self) -> Option<Job<T>> {
        let mut retry = None;
        if let Some(mut job) = self.queue.pop_front()
            && job.had_speech
            && self.words_since_segment == 0
        {
            if !job.retried && self.queue.is_empty() {
                job.retried = true;
                self.queue.push_back(job.clone());
                retry = Some(job);
            } else {
                self.gaps.push(job.offset);
            }
        }
        // Even a boundary with no queued job resets the word counter in Swift.
        self.words_since_segment = 0;
        retry
    }
    /// Finished/failed sessions retain the suspected gaps for review, while
    /// reset/new-session replaces the entire owner, including its word counter.
    pub fn retire_pending(&mut self) {
        self.queue.clear();
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn one_retry_only_when_no_later_segment_can_advance_the_watermark() {
        let mut c = Coverage::default();
        c.feed(0., "first", true);
        assert_eq!(c.segment_end().unwrap().audio, "first");
        assert_eq!(c.pending(), 1);
        assert!(c.segment_end().is_none());
        assert_eq!(c.gaps, vec![0.]);
        c.feed(3., "speech", true);
        c.feed(4., "next", true);
        assert!(c.segment_end().is_none());
        assert_eq!(c.gaps, vec![0., 3.]);
        c.word();
        assert!(c.segment_end().is_none());
        c.feed(8., "quiet", false);
        assert!(c.segment_end().is_none());
        assert_eq!(c.pending(), 0);
        c.feed(9., "retired", true);
        c.retire_pending();
        assert_eq!(c.gaps, vec![0., 3.]);
        assert_eq!(c.pending(), 0);
    }
}
