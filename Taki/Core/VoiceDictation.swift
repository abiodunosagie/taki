import AVFoundation
import Observation
import os
import Speech

/// Joins dictation results into one string: finished phrases are kept, the phrase still being
/// heard is replaced as the recognizer revises it.
struct TranscriptAccumulator: Equatable {
    private(set) var finished = ""
    private(set) var volatile = ""

    mutating func add(_ text: String, isFinal: Bool) {
        if isFinal {
            finished = Self.join(finished, text)
            volatile = ""
        } else {
            volatile = text
        }
    }

    var text: String { Self.join(finished, volatile) }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

/// Push-to-talk dictation, on the Mac itself (macOS 26 SpeechAnalyzer, no audio leaves the Mac).
/// `start` opens the microphone, `finish` stops it and hands back the text; the caller decides
/// where it goes. One session at a time.
@MainActor
@Observable
final class VoiceDictation {
    enum State: Equatable { case idle, preparing(String), listening, failed(String) }

    private(set) var state: State = .idle
    private(set) var transcript = TranscriptAccumulator()

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var session = 0                     // a stale start never overwrites a newer one

    var isActive: Bool {
        switch state {
        case .preparing, .listening: true
        case .idle, .failed: false
        }
    }

    private static let log = Logger(subsystem: "Taki", category: "dictation")

    /// True from the moment `finish` starts until it hands back the text.
    private(set) var isFinishing = false

    /// Listening, starting or finishing: a new session cannot begin yet.
    var isBusy: Bool { isActive || isFinishing }

    func start() async {
        guard !isBusy else { return }
        session += 1
        let mine = session
        transcript = TranscriptAccumulator()
        state = .preparing("Starting the microphone")
        // Everything opened so far, so a failure or a stale start closes all of it.
        var engine: AVAudioEngine?
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var results: Task<Void, Never>?
        var analyzer: SpeechAnalyzer?
        func abandon() async {
            if let engine, let continuation { Self.stopCapture(engine, continuation) }
            results?.cancel()
            await analyzer?.cancelAndFinishNow()
        }
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw DictationError("Taki has no microphone access. Turn it on in System Settings, Privacy and Security, Microphone.")
            }
            let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en_US")
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                guard mine == session else { return }
                state = .preparing("Downloading the speech model (once)")
                try await request.downloadAndInstall()
            }
            guard mine == session else { return }
            let made = SpeechAnalyzer(modules: [transcriber])
            analyzer = made
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw DictationError("Dictation is not available on this Mac right now. Try again in a moment.")
            }
            try await made.prepareToAnalyze(in: format)
            let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
            let mic = AVAudioEngine()
            engine = mic
            continuation = feed
            try Self.tapMicrophone(mic, into: feed, as: format)
            guard mine == session else { await abandon(); return }
            results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.transcript.add(String(result.text.characters), isFinal: result.isFinal)
                    }
                } catch {
                    // The words heard so far are still typed; the reason goes to the log.
                    Self.log.error("Dictation results ended: \(error.localizedDescription, privacy: .public)")
                }
            }
            try await made.start(inputSequence: stream)
            // Let go (or cancelled) while the microphone was still starting: close everything.
            guard mine == session else { await abandon(); return }
            self.resultsTask = results
            self.engine = mic
            self.analyzer = made
            self.input = feed
            state = .listening
        } catch {
            await abandon()
            guard mine == session else { return }
            teardown()
            if let known = error as? DictationError {
                state = .failed(known.message)
            } else {
                Self.log.error("Dictation could not start: \(error.localizedDescription, privacy: .public)")
                state = .failed("Dictation could not start. Try again in a moment.")
            }
        }
    }

    /// Longest wait for the last words after the microphone closes, so finishing never hangs.
    static let finishTimeout: Duration = .seconds(3)

    /// Stops listening and returns what was said (empty when nothing was heard).
    func finish() async -> String {
        guard isActive, !isFinishing else { return "" }
        isFinishing = true
        defer { isFinishing = false }
        session += 1
        if let engine, let input { Self.stopCapture(engine, input) }
        let analyzer = analyzer, results = resultsTask
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await analyzer?.finalizeAndFinishThroughEndOfInput()
                await results?.value
            }
            group.addTask { try? await Task.sleep(for: Self.finishTimeout) }
            await group.next()
            group.cancelAll()
        }
        let text = transcript.text
        teardown()
        state = .idle
        return text
    }

    func cancel() {
        session += 1
        if let engine, let input { Self.stopCapture(engine, input) }
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        teardown()
        state = .idle
    }

    func clearFailure() { if case .failed = state { state = .idle } }

    /// Shows why dictation could not begin (for example, no terminal tab to type into).
    func showProblem(_ message: String) { if !isActive { state = .failed(message) } }

    private func teardown() {
        resultsTask?.cancel()
        resultsTask = nil
        engine = nil
        analyzer = nil
        input = nil
    }

    /// Closes the microphone and ends the audio stream the analyzer reads.
    private nonisolated static func stopCapture(_ engine: AVAudioEngine, _ input: AsyncStream<AnalyzerInput>.Continuation) {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        input.finish()
    }

    /// Feeds the microphone into the analyzer, converted to the format the model wants. The tap
    /// runs on the audio thread; it only converts and yields.
    private nonisolated static func tapMicrophone(_ engine: AVAudioEngine, into continuation: AsyncStream<AnalyzerInput>.Continuation,
                                                  as format: AVAudioFormat) throws {
        let node = engine.inputNode
        let native = node.outputFormat(forBus: 0)
        guard native.sampleRate > 0, let converter = AVAudioConverter(from: native, to: format) else {
            throw DictationError("No microphone is connected.")
        }
        node.installTap(onBus: 0, bufferSize: 2048, format: native) { buffer, _ in
            let ratio = format.sampleRate / native.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
        }
        engine.prepare()
        try engine.start()
    }
}

struct DictationError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
