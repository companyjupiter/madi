import Foundation

@main
struct EnginePathPolicyTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if !cond {
                failures += 1
                print("FAIL: \(msg)")
            }
        }

        let root = URL(fileURLWithPath: "/tmp/sovereign-segs", isDirectory: true)

        check(EnginePathPolicy.streamWavIsAllowed(
            URL(fileURLWithPath: "/tmp/sovereign-segs/seg00001.wav"),
            roots: [root]
        ), "allows wav under configured root")

        check(!EnginePathPolicy.streamWavIsAllowed(
            URL(fileURLWithPath: "/tmp/sovereign-segs/seg00001.mp3"),
            roots: [root]
        ), "rejects non-wav extension")

        check(!EnginePathPolicy.streamWavIsAllowed(
            URL(fileURLWithPath: "/tmp/sovereign-segs2/seg00001.wav"),
            roots: [root]
        ), "rejects sibling prefix")

        check(!EnginePathPolicy.streamWavIsAllowed(
            URL(fileURLWithPath: "/private/etc/hosts"),
            roots: [root]
        ), "rejects unrelated absolute path")

        check(EnginePathPolicy.pathList([root, URL(fileURLWithPath: "/tmp/sovereign-decode", isDirectory: true)])
            == "/tmp/sovereign-segs:/tmp/sovereign-decode", "serializes roots for engine env")

        if failures == 0 {
            print("✅ EnginePathPolicy: all checks passed")
        } else {
            print("❌ \(failures) failure(s)")
            exit(1)
        }
    }
}
