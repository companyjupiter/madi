#[cfg(target_os = "macos")]
fn main() {
    use std::io::{self, Read};
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let inputs: Vec<String> = serde_json::from_str(&input).unwrap();
    let results: Vec<_> = inputs
        .iter()
        .map(|s| {
            serde_json::json!({
                "title": madi_platform::title::sanitize(s), "prompt": madi_core::title::prompt(s)
            })
        })
        .collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("The native title oracle requires macOS Foundation");
    std::process::exit(1);
}
