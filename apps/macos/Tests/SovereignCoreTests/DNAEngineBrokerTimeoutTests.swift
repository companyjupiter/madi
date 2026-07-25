// DNAEngineBrokerTimeoutTests — the wedge-recovery path.
//
// The failure being guarded: DNAEngineBroker serializes ONE resident DNA3
// process for live captions, interim captions, the action rail and the summary.
// `active` used to be cleared only by the engine's own turn terminator, and
// pump() is gated on `active == nil`, so a turn that never produced
// "[perf] generation" stopped every DNA client permanently, with no log and no
// user-visible error.
//
// TranslateStreamParserTests replay captured bytes; these drive a real child
// process speaking the engine's stdout protocol (a stub shell script — never the
// DNA3 binary), because the recovery being tested IS process lifecycle:
// watchdog → SIGTERM → terminationHandler → relaunch → READY → drain the queue.

import XCTest
@testable import SovereignCore

final class DNAEngineBrokerTimeoutTests: XCTestCase {

    // MARK: - stub engine

    /// Speaks the engine's stdout contract. A line beginning "WEDGE" is dropped
    /// silently — exactly what main.zig's over-long/empty-line paths used to do.
    private static let stubEngine = """
    #!/bin/sh
    printf 'READY\\n'
    while IFS= read -r line; do
      case "$line" in
        WEDGE*) ;;
        '%%PFX '*) printf 'PFX_OK 0 12\\n' ;;
        *) printf '[perf] prefill: 1 tok in 1.0ms (1000.0 tok/s)\\n'
           printf 'ok:%s' "$line"
           printf '\\n[perf] generation: 1 tok in 1.0ms (1000.0 tok/s)\\n' ;;
      esac
    done
    """

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dna-broker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeStubEngine() throws -> URL {
        let url = scratch.appendingPathComponent("stub-engine")
        try Self.stubEngine.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Attached broker whose turns time out fast enough for a unit test.
    @MainActor
    private func makeBroker(timeout: TimeInterval = 0.5) throws -> (DNAEngineBroker, UUID, XCTestExpectation) {
        let broker = DNAEngineBroker()
        broker.turnTimeoutOverride = timeout
        let client = UUID()
        let ready = expectation(description: "engine READY")
        ready.assertForOverFulfill = false   // a relaunch fires READY again
        let ok = broker.attach(client: client, engine: try makeStubEngine(),
                               model: scratch.appendingPathComponent("model.gguf"),
                               onReady: { ready.fulfill() })
        XCTAssertTrue(ok, "stub engine failed to spawn")
        return (broker, client, ready)
    }

    // MARK: - the wedge

    /// A turn the engine never terminates must not stop the lane: the request
    /// completes (with nil), and the NEXT request still gets a real reply.
    @MainActor
    func testUnterminatedTurnTimesOutAndTheLaneKeepsWorking() async throws {
        let (broker, client, ready) = try makeBroker()
        defer { broker.detach(client: client) }
        await fulfillment(of: [ready], timeout: 10)

        var wedgedResult: String? = "not-called"
        let wedged = expectation(description: "wedged turn completes")
        broker.submit(client: client, prompt: "WEDGE me", priority: .committedCaption) {
            wedgedResult = $0; wedged.fulfill()
        }
        await fulfillment(of: [wedged], timeout: 10)
        XCTAssertNil(wedgedResult, "a timed-out turn must complete with nil, not hang")
        XCTAssertEqual(broker.wedgeRestarts, 1, "the watchdog should have restarted the engine once")

        // The whole point: the lane recovered rather than being permanently stuck.
        var nextResult: String?
        let next = expectation(description: "next turn completes")
        broker.submit(client: client, prompt: "hello", priority: .committedCaption) {
            nextResult = $0; next.fulfill()
        }
        await fulfillment(of: [next], timeout: 10)
        XCTAssertEqual(nextResult, "ok:hello")
    }

    /// Requests QUEUED behind a wedged turn must fail too — never be dropped
    /// silently, or a fan-out caller (SummaryEngine's map/fold counts
    /// completions) wedges even though the broker recovered.
    @MainActor
    func testQueuedRequestsBehindAWedgeAllComplete() async throws {
        let (broker, client, ready) = try makeBroker()
        defer { broker.detach(client: client) }
        await fulfillment(of: [ready], timeout: 10)

        let all = expectation(description: "every request completes")
        all.expectedFulfillmentCount = 3
        broker.submit(client: client, prompt: "WEDGE", priority: .committedCaption) { _ in all.fulfill() }
        broker.submit(client: client, prompt: "queued-a", priority: .postSession) { _ in all.fulfill() }
        broker.submit(client: client, prompt: "queued-b", priority: .postSession) { _ in all.fulfill() }
        await fulfillment(of: [all], timeout: 10)
    }

    /// A healthy turn must not be killed by its own watchdog, and must leave the
    /// engine untouched (no restart, no reload).
    @MainActor
    func testHealthyTurnDoesNotRestartTheEngine() async throws {
        let (broker, client, ready) = try makeBroker(timeout: 5)
        defer { broker.detach(client: client) }
        await fulfillment(of: [ready], timeout: 10)

        var result: String?
        let done = expectation(description: "turn completes")
        broker.submit(client: client, prompt: "annyeong", priority: .interimCaption) {
            result = $0; done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(result, "ok:annyeong")
        XCTAssertEqual(broker.wedgeRestarts, 0)
    }

    /// cancelPending drops QUEUED work only, and completes what it drops.
    @MainActor
    func testCancelPendingCompletesDroppedRequests() async throws {
        let (broker, client, ready) = try makeBroker(timeout: 5)
        defer { broker.detach(client: client) }
        await fulfillment(of: [ready], timeout: 10)

        // Occupy the engine so the rest genuinely queue.
        let busy = expectation(description: "in-flight turn completes")
        broker.submit(client: client, prompt: "in-flight", priority: .committedCaption) { _ in busy.fulfill() }

        let cancelled = expectation(description: "queued requests complete with nil")
        cancelled.expectedFulfillmentCount = 2
        var results: [String?] = []
        for tag in ["queued-a", "queued-b"] {
            broker.submit(client: client, prompt: tag, priority: .postSession) {
                results.append($0); cancelled.fulfill()
            }
        }
        broker.cancelPending(client: client)
        await fulfillment(of: [cancelled, busy], timeout: 10)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0 == nil }, "cancelled requests must complete with nil")
    }

    // MARK: - budget derivation

    func testBudgetIsDerivedFromTheEnginesOwnGenerationCap() {
        // 512 steps is what the broker pins as SOV_NSTEPS.
        let live4B = DNATurnBudget.seconds(promptBytes: 200, steps: 512, rates: DNATurnBudget.rates4B)
        let live2B = DNATurnBudget.seconds(promptBytes: 200, steps: 512, rates: DNATurnBudget.rates2B)

        // Must sit well above a full-length legitimate reply, never near it.
        let worstCase4B = 200.0 / DNATurnBudget.rates4B.prefill + 512.0 / DNATurnBudget.rates4B.decode
        XCTAssertGreaterThan(live4B, worstCase4B * 2)
        XCTAssertGreaterThan(live4B, live2B, "the slower model must get the longer budget")

        // Longer prompts (summary folds) get proportionally more room.
        let summary4B = DNATurnBudget.seconds(promptBytes: 2400, steps: 512, rates: DNATurnBudget.rates4B)
        XCTAssertGreaterThan(summary4B, live4B)

        // Clamps hold at both ends.
        XCTAssertEqual(DNATurnBudget.seconds(promptBytes: 0, steps: 0, rates: DNATurnBudget.rates2B),
                       DNATurnBudget.minimum)
        XCTAssertEqual(DNATurnBudget.seconds(promptBytes: 10_000_000, steps: 512, rates: DNATurnBudget.rates4B),
                       DNATurnBudget.maximum)
    }

    func testUnknownEngineGetsTheSlowerProfile() {
        XCTAssertEqual(DNATurnBudget.rates(forEnginePath: "/x/translate-engine-2b"), DNATurnBudget.rates2B)
        XCTAssertEqual(DNATurnBudget.rates(forEnginePath: "/x/translate-engine-4b"), DNATurnBudget.rates4B)
        XCTAssertEqual(DNATurnBudget.rates(forEnginePath: "/x/some-future-engine"), DNATurnBudget.rates4B)
    }

    func testTimeoutOverrideIsReadFromTheEnvironment() {
        XCTAssertEqual(DNATurnBudget.override(["MADI_DNA_TIMEOUT_MS": "2500"]), 2.5)
        XCTAssertNil(DNATurnBudget.override([:]))
        XCTAssertNil(DNATurnBudget.override(["MADI_DNA_TIMEOUT_MS": "0"]))
        XCTAssertNil(DNATurnBudget.override(["MADI_DNA_TIMEOUT_MS": "nope"]))
    }
}
