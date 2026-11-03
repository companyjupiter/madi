use std::{io::Read, path::Path};

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let paths: Vec<String> = serde_json::from_str(&input).unwrap();
    let records: Vec<_> = paths
        .iter()
        .map(|path| {
            let path = Path::new(path);
            serde_json::json!({
                "accepted": madi_platform::media_file::accepts_drop(path),
                "summary": madi_platform::media_file::summary(path),
            })
        })
        .collect();
    println!("{}", serde_json::to_string(&records).unwrap());
}
