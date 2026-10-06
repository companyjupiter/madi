import Foundation

/// Translates the existing process protocol (also used by dictation) into the
/// session port. The coordinator stamps callbacks with each process's identity.
@MainActor
final class SessionEngineAdapter: SessionEngine, EngineProcessDelegate {
    var onOutput: ((SessionEngineOutput) -> Void)?
    private let process: EngineProcess

    init(config: EngineProcess.Config) { process = EngineProcess(config: config) }
    func start() throws {
        process.delegate = self
        process.onDiagnosticLine = { [weak self] in self?.onOutput?(.diagnostic($0)) }
        try process.start()
    }
    func feed(offset: Double, wav: URL) { process.feed(offset: offset, wav: wav) }
    func feedPreview(wav: URL, forced: String) { process.feedPreview(wav: wav, forced: forced) }
    func flush() { process.flush() }
    func terminate() {
        process.delegate = nil; process.onDiagnosticLine = nil
        process.terminate()
    }
    func engineDidBecomeReady() { onOutput?(.ready) }
    func engine(didEmit event: EngineEvent) { onOutput?(.event(event)) }
    func engine(didEmitStructured event: StructuredEvent) { onOutput?(.structured(event)) }
    func engineDidFlush() { onOutput?(.flushed) }
    func engine(didTerminate code: Int32) { onOutput?(.terminated(code)) }
}
