import Speech
import AVFoundation

/// Kapselt einen SFSpeechRecognizer-Lauf und rotiert bei Sprechpausen die Anfrage,
/// damit auch lange Aufnahmen stabil bleiben. Ergebnisse werden abschnittsweise bestätigt.
/// `append` darf von Audio-Threads aufgerufen werden; alles andere läuft auf dem Main Actor.
@MainActor
final class SpeechSession {
    /// Zustand, der auch vom Audio-Thread gelesen wird – immer unter `lock`.
    private final class Shared {
        let lock = NSLock()
        var running = false
        var rotating = false
        var request: SFSpeechAudioBufferRecognitionRequest?
        var segmentStart = Date()
        var lastChange = Date()
        var hasPartial = false

        func noteChange(hasPartial: Bool) {
            lock.lock(); lastChange = Date(); self.hasPartial = hasPartial; lock.unlock()
        }
    }

    private let recognizer: SFSpeechRecognizer
    nonisolated private let shared = Shared()
    private var task: SFSpeechRecognitionTask?
    private var partial = ""
    private var pendingFinal: (@MainActor () -> Void)?
    private var generation = 0

    nonisolated let autoSegment: Bool
    nonisolated let softLimit: TimeInterval
    nonisolated let hardLimit: TimeInterval
    var onPartial: (@MainActor (String) -> Void)?
    var onCommitted: (@MainActor (String) -> Void)?

    init?(localeIdentifier: String, autoSegment: Bool = true, softLimit: TimeInterval = 25, hardLimit: TimeInterval = 70) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), r.isAvailable else { return nil }
        recognizer = r
        self.autoSegment = autoSegment
        self.softLimit = softLimit
        self.hardLimit = hardLimit
    }

    var supportsOnDevice: Bool { recognizer.supportsOnDeviceRecognition }

    func begin() {
        shared.lock.lock(); shared.running = true; shared.lock.unlock()
        partial = ""
        newRequest()
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        shared.lock.lock()
        let running = shared.running
        let req = shared.request
        shared.lock.unlock()
        guard running else { return }
        req?.append(buffer)
        checkRotation()
    }

    func end(completion: @escaping @MainActor () -> Void) {
        shared.lock.lock()
        let req = shared.request
        shared.running = false
        shared.request = nil
        shared.lock.unlock()
        guard req != nil else { completion(); return }
        var done = false
        let finish: @MainActor () -> Void = {
            if done { return }
            done = true
            completion()
        }
        pendingFinal = finish
        req?.endAudio()
        let gen = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self = self, self.generation == gen else { return }
            self.commitPartialIfNeeded()
            self.task?.cancel()
            self.pendingFinal = nil
            finish()
        }
    }

    private func newRequest() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        req.taskHint = .dictation
        shared.lock.lock()
        shared.request = req
        shared.segmentStart = Date()
        shared.lastChange = Date()
        shared.hasPartial = false
        shared.lock.unlock()
        partial = ""
        generation += 1
        let gen = generation

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    if text != self.partial {
                        self.partial = text
                        self.shared.noteChange(hasPartial: !text.isEmpty)
                        self.onPartial?(text)
                    }
                    if result.isFinal {
                        self.commit(text)
                        self.afterSegmentEnded(gen)
                    }
                } else if error != nil {
                    self.commitPartialIfNeeded()
                    self.afterSegmentEnded(gen)
                }
            }
        }
    }

    private func afterSegmentEnded(_ gen: Int) {
        shared.lock.lock()
        let running = shared.running
        let rotating = shared.rotating
        shared.rotating = false
        shared.lock.unlock()

        if !running {
            if let f = pendingFinal { pendingFinal = nil; f() }
            return
        }
        // Nur neu starten, wenn dieses Segment das aktuelle war und keine Rotation lief.
        if !rotating && gen == generation {
            newRequest()
        }
    }

    private func commitPartialIfNeeded() {
        let p = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { commit(p) }
        partial = ""
    }

    private func commit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        onPartial?("")
        guard !t.isEmpty else { return }
        onCommitted?(t)
    }

    private nonisolated func checkRotation() {
        guard autoSegment else { return }
        shared.lock.lock()
        defer { shared.lock.unlock() }
        guard shared.running, !shared.rotating else { return }
        let elapsed = Date().timeIntervalSince(shared.segmentStart)
        let quiet = Date().timeIntervalSince(shared.lastChange)
        let shouldRotate = (elapsed > softLimit && quiet > 0.9 && shared.hasPartial) || elapsed > hardLimit
        guard shouldRotate else { return }
        shared.rotating = true
        Task { @MainActor [weak self] in self?.rotate() }
    }

    private func rotate() {
        shared.lock.lock()
        let running = shared.running
        let old = shared.request
        shared.lock.unlock()
        guard running else { return }
        old?.endAudio()
        newRequest()
    }
}

enum AudioUtil {
    /// Wandelt einen CMSampleBuffer (z. B. aus ScreenCaptureKit) in einen AVAudioPCMBuffer.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var copy = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &copy) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
