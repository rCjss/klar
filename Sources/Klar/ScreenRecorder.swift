import AVFoundation
import ScreenCaptureKit
import AppKit
import Combine

/// Nimmt SCStream-Samples auf der Recorder-Queue entgegen und schreibt sie in eine .mov-Datei.
final class RecordingSink: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var sessionStarted = false
    private var finished = false
    let queue = DispatchQueue(label: "klar.recorder")
    var onError: ((Error) -> Void)?

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)
        writer.add(audioInput)
        super.init()
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Klar", code: 1) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, !finished, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  status == SCFrameStatus.complete.rawValue,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData {
                adaptor.append(pixelBuffer, withPresentationTime: pts)
            }
        case .audio:
            guard sessionStarted, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sb)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    func finish(completion: @escaping () -> Void) {
        queue.async { [self] in
            guard !finished else { completion(); return }
            finished = true
            videoInput.markAsFinished()
            audioInput.markAsFinished()
            if writer.status == .writing {
                writer.finishWriting { completion() }
            } else {
                completion()
            }
        }
    }
}

/// Ab macOS 15 schreibt ScreenCaptureKit die Datei selbst (inkl. Systemton und optional Mikrofon).
@available(macOS 15.0, *)
final class RecordingOutputDelegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    var onFinished: (() -> Void)?
    var onError: ((Error) -> Void)?
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { onFinished?() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { onError?(error) }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }
}

/// Bildschirmaufnahme des Hauptdisplays inkl. Systemton als .mov (H.264 / AAC).
@MainActor
final class ScreenRecorder: ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastFile: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var files: [URL] = []

    private var stream: SCStream?
    private var sink: RecordingSink?
    private var modernOutput: AnyObject?
    private var modernDelegate: AnyObject?

    private init() { reloadFiles() }

    func reloadFiles() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Storage.recordings, includingPropertiesForKeys: [.creationDateKey])) ?? []
        files = urls.filter { $0.pathExtension == "mov" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
    }

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        errorMessage = nil
        Task { await begin() }
    }

    private func begin() async {
        guard Permissions.requestScreen() else { errorMessage = "Bildschirmaufnahme-Freigabe fehlt."; return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { errorMessage = "Kein Display gefunden."; return }
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let width = Int(CGFloat(display.width) * scale)
            let height = Int(CGFloat(display.height) * scale)

            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.queueDepth = 6

            let url = Storage.recordings.appendingPathComponent("Aufnahme " + Format.fileStamp.string(from: Date()) + ".mov")

            if #available(macOS 15.0, *) {
                if Settings.shared.recordMicInScreenRecording, await Permissions.requestMicrophone() {
                    config.captureMicrophone = true
                }
                let delegate = RecordingOutputDelegate()
                delegate.onError = { [weak self] error in
                    Task { @MainActor in
                        self?.errorMessage = "Aufnahme abgebrochen: \(error.localizedDescription)"
                        self?.stop()
                    }
                }
                let recConfig = SCRecordingOutputConfiguration()
                recConfig.outputURL = url
                recConfig.outputFileType = .mov
                recConfig.videoCodecType = .h264
                let output = SCRecordingOutput(configuration: recConfig, delegate: delegate)
                let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
                try stream.addRecordingOutput(output)
                try await stream.startCapture()
                self.modernOutput = output
                self.modernDelegate = delegate
                self.stream = stream
                lastFile = url
                startedAt = Date()
                isRecording = true
                AppDelegate.shared?.refreshStatusIcon()
                return
            }

            let sink = try RecordingSink(url: url, width: width, height: height)
            sink.onError = { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = "Aufnahme abgebrochen: \(error.localizedDescription)"
                    self?.stop()
                }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: sink)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
            self.sink = sink
            self.stream = stream
            lastFile = url
            startedAt = Date()
            isRecording = true
            AppDelegate.shared?.refreshStatusIcon()
        } catch {
            errorMessage = "Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        startedAt = nil
        let s = stream
        let sink = self.sink
        stream = nil
        self.sink = nil
        AppDelegate.shared?.refreshStatusIcon()
        let output = modernOutput
        let delegate = modernDelegate
        modernOutput = nil
        modernDelegate = nil
        Task {
            if #available(macOS 15.0, *), let s = s, let output = output as? SCRecordingOutput,
               let delegate = delegate as? RecordingOutputDelegate {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    var resumed = false
                    delegate.onFinished = { if !resumed { resumed = true; cont.resume() } }
                    delegate.onError = { _ in if !resumed { resumed = true; cont.resume() } }
                    do { try s.removeRecordingOutput(output) } catch { if !resumed { resumed = true; cont.resume() } }
                }
                try? await s.stopCapture()
            } else {
                try? await s?.stopCapture()
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    if let sink = sink { sink.finish { cont.resume() } } else { cont.resume() }
                }
            }
            reloadFiles()
            if let f = lastFile { NSWorkspace.shared.activateFileViewerSelecting([f]) }
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func delete(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reloadFiles()
    }
}
