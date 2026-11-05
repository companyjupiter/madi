use std::io::{self, Read};
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let pairs: Vec<(String, String)> = serde_json::from_str(&input).unwrap();
    let native: Vec<_> = pairs
        .iter()
        .map(|(a, b)| madi_platform::reconcile_client::speaker_names_equal(a, b))
        .collect();
    let portable: Vec<_> = pairs
        .iter()
        .map(|(a, b)| madi_core::reconcile::names_equal(a, b))
        .collect();
    println!(
        "{}",
        serde_json::json!({"native":native,"portable":portable})
    );
}
