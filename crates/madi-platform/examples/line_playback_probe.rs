//! Runs the actual shipping AVPlayer adapter against a caller-owned silent WAV.
#[cfg(all(target_os = "macos", debug_assertions))]
fn main() {
    use madi_core::transcript::Uuid;
    use madi_platform::line_playback::Player;
    use std::{
        cell::RefCell,
        path::PathBuf,
        rc::Rc,
        time::{Duration, Instant},
    };
    unsafe extern "C" {
        fn madi_capture_pump();
    }
    fn pump_until(mut ready: impl FnMut() -> bool, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while !ready() && Instant::now() < deadline {
            unsafe { madi_capture_pump() };
        }
        ready()
    }
    fn drain_for(duration: Duration) {
        let _ = pump_until(|| false, duration);
    }
    let path = PathBuf::from(std::env::args().nth(1).expect("silent WAV path required"));
    let observations = Rc::new(RefCell::new(Vec::<Option<Uuid>>::new()));
    let captured = observations.clone();
    let mut player = Player::new(move |line| captured.borrow_mut().push(line)).unwrap();
    let a = Uuid::from_u128(1);
    let b = Uuid::from_u128(2);
    assert_eq!(*observations.borrow(), [None]);
    let mut boundaries = Vec::new();
    for (from, to) in [(0.0, 0.3), (0.5, 0.5), (-0.1, 0.4)] {
        let start = Instant::now();
        player.toggle(&path, a, from, to).unwrap();
        assert_eq!(observations.borrow().last(), Some(&Some(a)));
        let stopped = pump_until(
            || observations.borrow().last() == Some(&None),
            Duration::from_secs(5),
        );
        let elapsed = start.elapsed().as_secs_f64();
        let minimum = f64::max(from + 0.3, to) - f64::max(0.0, from);
        boundaries.push(serde_json::json!({"from":from,"to":to,"elapsed":elapsed,"passed":stopped && elapsed >= minimum - 0.03}));
        // Keep exercising teardown even if the platform never advances its
        // playback clock. A failed boundary remains a failed overall verdict.
        player.stop();
    }
    player.toggle(&path, a, 0.1, 1.0).unwrap();
    player.toggle(&path, a, 0.1, 1.0).unwrap();
    assert_eq!(observations.borrow().last(), Some(&None));
    let stopped_count = observations.borrow().len();
    drain_for(Duration::from_millis(100));
    assert_eq!(
        observations.borrow().len(),
        stopped_count,
        "stale seek after tap-again"
    );
    player.toggle(&path, a, 0.0, 0.3).unwrap();
    player.toggle(&path, b, 1.0, 1.3).unwrap();
    player.toggle(&path, a, 2.0, 2.5).unwrap();
    assert_eq!(observations.borrow().last(), Some(&Some(a)));
    let switched = Instant::now();
    let rapid_boundary = pump_until(
        || observations.borrow().last() == Some(&None),
        Duration::from_secs(5),
    ) && switched.elapsed() >= Duration::from_millis(470);
    player.stop();
    player.toggle(&path, b, 1.0, 2.0).unwrap();
    player.stop();
    assert_eq!(observations.borrow().last(), Some(&None));
    assert!(player.toggle(&path, a, f64::NAN, 1.0).is_err());
    player.toggle(&path, a, 0.2, 2.0).unwrap();
    drop(player);
    assert_eq!(observations.borrow().last(), Some(&None));
    let dropped_count = observations.borrow().len();
    drain_for(Duration::from_millis(100));
    assert_eq!(
        observations.borrow().len(),
        dropped_count,
        "callback after native owner destruction"
    );
    let passed = rapid_boundary && boundaries.iter().all(|b| b["passed"] == true);
    println!(
        "{}",
        serde_json::json!({"status":if passed {"passed"} else {"failed"},"boundaries":boundaries,"tapAgainStops":true,"rapidSameLineBoundary":rapid_boundary,"stopPendingSeek":true,"dropPendingSeek":true,"invalidSpanRejected":true,"events":*observations.borrow(),"scope":"Actual AVPlayer with silent file; no UI or microphone input; output-device playback quality not certified"})
    );
    if !passed {
        std::process::exit(1);
    }
}
#[cfg(not(all(target_os = "macos", debug_assertions)))]
fn main() {
    eprintln!("Native playback probe requires a debug macOS build");
    std::process::exit(1);
}
