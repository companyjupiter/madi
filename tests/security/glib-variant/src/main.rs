//! Exercise the real variadic GLib FFI in optimized code, with owned input alive.
use glib::{variant::ToVariant, Variant};

fn main() {
    let mode = std::env::args()
        .nth(1)
        .expect("forward, reverse or alternating");
    for strings in [
        vec![],
        vec![""],
        vec!["첫 문장", "é", "e\u{301}", "🦀", "last"],
    ] {
        let variant =
            Variant::array_from_iter::<String>(strings.iter().map(|text| text.to_variant()));
        let mut actual = variant.array_iter_str().unwrap();
        let mut expected = strings.iter().copied();
        match mode.as_str() {
            "forward" => assert_eq!(actual.collect::<Vec<_>>(), strings),
            "reverse" => assert_eq!(
                actual.rev().collect::<Vec<_>>(),
                expected.rev().collect::<Vec<_>>()
            ),
            "alternating" => {
                while expected.len() > 0 {
                    assert_eq!(actual.next(), expected.next());
                    assert_eq!(actual.next_back(), expected.next_back());
                    assert_eq!(actual.len(), expected.len());
                }
                assert_eq!(actual.next(), None);
                assert_eq!(actual.next_back(), None);
            }
            _ => panic!("unknown mode"),
        }
    }
    println!("{{\"status\":\"PASS\",\"mode\":\"{mode}\"}}");
}
