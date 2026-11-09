//! Shared DNA lane policy from DNAEngineBroker and DNATurnBudget.

pub const GENERATION_STEPS: i64 = 512;
pub const BACKGROUND_AGING_SECONDS: f64 = 90.0;
pub const MAX_WEDGE_RESTARTS: u32 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum Priority {
    PostSession = 10,
    LiveRail = 30,
    InterimCaption = 80,
    CommittedCaption = 100,
}

impl Priority {
    pub fn is_caption(self) -> bool {
        self as i32 >= Self::InterimCaption as i32
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Candidate {
    pub priority: i32,
    pub sequence: u64,
    pub waited_seconds: f64,
}

/// Highest priority, FIFO within a lane. Captions bypass pressure; background
/// work waits for pressure to clear or the 90-second starvation valve.
pub fn eligible_index(items: &[Candidate], caption_pressure: i64, aging: f64) -> Option<usize> {
    let mut best: Option<usize> = None;
    for (index, item) in items.iter().enumerate() {
        if item.priority < Priority::InterimCaption as i32
            && caption_pressure != 0
            && item.waited_seconds < aging
        {
            continue;
        }
        if best.is_none_or(|old| {
            item.priority > items[old].priority
                || (item.priority == items[old].priority && item.sequence < items[old].sequence)
        }) {
            best = Some(index);
        }
    }
    best
}

/// The shipping broker normalizes CR/LF before adding the protocol delimiter.
pub fn one_line(text: &str) -> String {
    text.replace(['\n', '\r'], " ")
        .trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}')
        .to_owned()
}

pub fn turn_budget_seconds(prompt_bytes: i64, steps: i64, engine_path: &str) -> f64 {
    let (prefill, decode) = if engine_path.ends_with("-2b") {
        (600.0, 125.0)
    } else {
        (300.0, 63.0)
    };
    let modelled = prompt_bytes.max(0) as f64 / prefill + steps.max(0) as f64 / decode;
    (modelled * 3.0 + 5.0).clamp(20.0, 180.0)
}

/// Invalid/nonfinite values must not panic the native timer. Shipping positive
/// finite millisecond overrides are preserved; no arbitrary upper cap is added.
pub fn timeout_override(raw: &str) -> Option<f64> {
    let milliseconds: f64 = raw.parse().ok()?;
    (milliseconds.is_finite() && milliseconds > 0.0).then_some(milliseconds / 1000.0)
}
