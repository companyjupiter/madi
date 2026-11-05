#[cfg(target_os = "macos")]
fn main() {
    use madi_platform::workspace_scan::{self, Node};
    use objc2::{AllocAnyThread, rc::autoreleasepool};
    use objc2_foundation::{NSCalendar, NSCalendarIdentifierGregorian, NSString, NSTimeZone};
    use serde::Deserialize;
    use serde_json::{Value, json};
    use std::{
        io::Read,
        path::{Path, PathBuf},
    };
    #[derive(Deserialize)]
    struct Meeting {
        date: f64,
        markdown: String,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Case {
        now: f64,
        zone: String,
        first_weekday: usize,
        min_days: usize,
        meetings: Vec<Meeting>,
    }
    #[derive(Deserialize)]
    struct Input {
        roots: Vec<PathBuf>,
        cases: Vec<Case>,
    }
    fn node(value: &Node, root: &Path) -> Value {
        json!({"path":value.path.strip_prefix(root).unwrap_or_else(|_|panic!("path {:?} root {:?}",value.path,root)).to_str().unwrap(),"name":value.name,"directory":value.is_dir,"transcript":value.is_transcript,"summary":value.is_summary,"children":value.children.as_ref().map(|children|children.iter().map(|child|node(child,root)).collect::<Vec<_>>())})
    }
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let input: Input = serde_json::from_str(&input).unwrap();
    let scans:Vec<_>=input.roots.iter().map(|root| {
        let nodes=workspace_scan::scan(root).unwrap();
        json!({"nodes":nodes.iter().map(|value|node(value,root)).collect::<Vec<_>>(),"recent":workspace_scan::recent(&nodes).iter().map(|node|node.path.strip_prefix(root).unwrap().to_str().unwrap()).collect::<Vec<_>>()})
    }).collect();
    let stats:Vec<_>=input.cases.iter().map(|case|autoreleasepool(|_| {
        let calendar=NSCalendar::initWithCalendarIdentifier(NSCalendar::alloc(),unsafe {NSCalendarIdentifierGregorian}).unwrap();
        calendar.setTimeZone(&NSTimeZone::timeZoneWithName(&NSString::from_str(&case.zone)).unwrap());
        calendar.setFirstWeekday(case.first_weekday);calendar.setMinimumDaysInFirstWeek(case.min_days);
        let mut stats=madi_core::workspace::Stats::default();
        for meeting in &case.meetings {if let Some(parsed)=madi_core::transcript::archive::parse(&meeting.markdown) {
            stats.add(&parsed.lines,workspace_scan::macos::weeks_ago(meeting.date,case.now,&calendar));
        }}
        json!({"count":stats.meeting_count,"seconds":format!("{:016x}",stats.total_seconds.to_bits()),"words":stats.total_words,"speakers":stats.speaker_sum,"thisWeek":stats.this_week_count,"trend":stats.weekly_trend,"avgSeconds":format!("{:016x}",stats.avg_seconds.to_bits()),"avgSpeakers":format!("{:016x}",stats.avg_speakers.to_bits()), "formattedWords":madi_platform::workspace_service::total_words_label(stats.total_words), "averageLabel":format!("{:.1}",stats.avg_speakers)})
    })).collect();
    println!("{}", json!({"scans":scans,"stats":stats}));
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("native workspace oracle requires macOS");
    std::process::exit(2);
}
