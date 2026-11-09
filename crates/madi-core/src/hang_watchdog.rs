//! SessionController's W2 progress-based hang rule; the native owner executes
//! replacement and only then refreshes/re-feeds its retained coverage queue.
use crate::session::Phase;

#[derive(Debug)]
pub struct Watchdog {
    last_activity: f64,
    pub recoveries: usize,
}
impl Watchdog {
    pub fn new(now: f64) -> Self {
        Self {
            last_activity: now,
            recoveries: 0,
        }
    }
    pub fn activity(&mut self, now: f64) {
        self.last_activity = now;
    }
    pub fn tick(&mut self, phase: &Phase, oldest_fed_at: Option<f64>, now: f64) -> bool {
        let Some(fed_at) = oldest_fed_at else {
            return false;
        };
        if matches!(phase, Phase::Recording | Phase::Paused)
            && now - fed_at.max(self.last_activity) > 45.0
        {
            self.recoveries += 1;
            return true;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_strictly_stalled_live_work_recovers_even_while_paused() {
        let mut w = Watchdog::new(0.);
        assert!(!w.tick(&Phase::Recording, Some(10.), 55.));
        w.activity(54.);
        assert!(!w.tick(&Phase::Recording, Some(10.), 99.));
        assert!(!w.tick(&Phase::Flushing, Some(10.), 100.));
        assert!(!w.tick(&Phase::Paused, None, 100.));
        assert!(w.tick(&Phase::Paused, Some(10.), 100.));
        assert!(!w.tick(&Phase::Recording, Some(100.), 101.));
        assert_eq!(w.recoveries, 1);
    }
}
