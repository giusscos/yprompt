//
//  MacCaptureService.swift
//  yprompt
//

#if os(macOS)
import AVFoundation
import Observation

/// Records takes on the Mac with a webcam (built-in, iPhone as a camera, or USB) or just the
/// microphone, into the same recordings the iPhone makes. Kept apart from the iPhone's camera
/// service: lenses, zoom, torch, rotation and the audio session don't exist here.
@Observable @MainActor
final class MacCaptureService: NSObject {
    /// True while a capture session runs, with a camera or, in audio-only mode, just the microphone.
    private(set) var isActive = false
    private(set) var isAudioOnly = false
    private(set) var isRecording = false
    private(set) var recordingStartDate: Date?
    /// Camera or microphone access was refused; the person has to allow it in System Settings.
    var permissionDenied = false
    /// Set when a piece finishes recording, to open its recording in the editor.
    var finished: RecordingSelection?
    /// Called with each finished piece, for opening it in the editor.
    @ObservationIgnored var onFinished: ((RecordingSelection) -> Void)?

    private(set) var cameras: [AVCaptureDevice] = []
    private(set) var selectedCameraID: String?

    private(set) var captureSession: AVCaptureSession?
    @ObservationIgnored private var movieOutput: AVCaptureMovieFileOutput?
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    /// Reading position when each piece's recording was stopped, by file name.
    @ObservationIgnored private var endProgress: [String: Double] = [:]
    /// Starting and stopping run here, one at a time and off the main thread.
    /// Starting and stopping run on this one thread, off the main thread. It has to be the same
    /// thread every time: stopping a session waits on the thread that started it, and a
    /// dispatch queue can hand the two calls to different threads, which hangs forever.
    @ObservationIgnored private let sessionThread = CaptureSessionThread.shared
    @ObservationIgnored private var startChain: Task<Void, Never>?
    @ObservationIgnored private var deviceObservers: [NSObjectProtocol] = []

    private static let cameraKey = "mac.camera"

    override init() {
        selectedCameraID = UserDefaults.standard.string(forKey: Self.cameraKey)
        super.init()
        refreshCameras()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.camerasChanged() }
            })
        }
    }

    var selectedCamera: AVCaptureDevice? {
        cameras.first { $0.uniqueID == selectedCameraID } ?? cameras.first
    }

    // MARK: - Cameras

    private func refreshCameras() {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified
        ).devices
    }

    private func camerasChanged() {
        let previous = selectedCamera?.uniqueID
        refreshCameras()
        // The camera in use went away (an iPhone walked off, a cable came out): use another.
        guard isActive, !isAudioOnly, !isRecording, selectedCamera?.uniqueID != previous else { return }
        useCamera(selectedCamera)
    }

    func selectCamera(_ device: AVCaptureDevice) {
        selectedCameraID = device.uniqueID
        UserDefaults.standard.set(device.uniqueID, forKey: Self.cameraKey)
        if isActive, !isAudioOnly, !isRecording { useCamera(device) }
    }

    private func useCamera(_ device: AVCaptureDevice?) {
        guard let session = captureSession else { return }
        session.beginConfiguration()
        if let videoInput { session.removeInput(videoInput) }
        videoInput = nil
        if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        session.commitConfiguration()
    }

    // MARK: - Session

    /// Starts the camera, or with `audioOnly` just the microphone. A session already running
    /// in the other mode is replaced.
    func requestPermissionsAndStart(audioOnly: Bool) async {
        let previous = startChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.start(audioOnly: audioOnly)
        }
        startChain = task
        await task.value
    }

    private func start(audioOnly: Bool) async {
        if isActive {
            guard isAudioOnly != audioOnly, !isRecording else { return }
            stop()
        }
        await sessionQueueIdle()
        let cameraGranted = audioOnly ? true : await Self.access(for: .video)
        let micGranted = await Self.access(for: .audio)
        guard cameraGranted && micGranted else {
            permissionDenied = true
            return
        }
        permissionDenied = false

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        if !audioOnly {
            guard let camera = selectedCamera,
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            videoInput = input
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        let output = AVCaptureMovieFileOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            movieOutput = output
        }
        session.commitConfiguration()

        sessionThread.run { [session] in session.startRunning() }
        // Returns once the session runs, so recording can start straight after. The preview
        // only gets the session then: attaching it while the session starts up crashes.
        await sessionQueueIdle()
        captureSession = session
        isAudioOnly = audioOnly
        isActive = true
    }

    private static func access(for type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    private func sessionQueueIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionThread.run { continuation.resume() }
        }
    }

    /// Stops the session. A piece being recorded is finished and kept.
    func stop() {
        if isRecording { movieOutput?.stopRecording() }
        let session = captureSession
        captureSession = nil
        movieOutput = nil
        videoInput = nil
        isActive = false
        isRecording = false
        recordingStartDate = nil
        sessionThread.run { [session] in session?.stopRunning() }
    }

    // MARK: - Recording

    /// Starts or stops recording a piece. `progress` is the reading position at that moment,
    /// so a later pickup can carry on from where this piece stopped.
    func toggleRecording(into target: RecordingTarget?, progress: Double) {
        if isRecording {
            if let file = movieOutput?.outputFileURL?.lastPathComponent { endProgress[file] = progress }
            movieOutput?.stopRecording()
        } else {
            guard let output = movieOutput, !output.isRecording else { return }
            let pending = RecordingStore.beginPiece(target ?? RecordingTarget(title: String(localized: "Take")),
                                                    kind: isAudioOnly ? .audio : .video, startProgress: progress)
            output.startRecording(to: pending.url, recordingDelegate: self)
            isRecording = true
            recordingStartDate = Date()
        }
    }
}

extension MacCaptureService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let file = outputFileURL.lastPathComponent
        let sendableError = error.map { $0 as NSError }
        Task { @MainActor [weak self] in
            // Stopping the whole session also lands here, after the state was already reset.
            if self?.movieOutput?.isRecording != true {
                self?.isRecording = false
                self?.recordingStartDate = nil
            }
            let progress = self?.endProgress.removeValue(forKey: file)
            guard let selection = await RecordingStore.completePiece(at: outputFileURL, error: sendableError,
                                                                     endProgress: progress) else { return }
            self?.finished = selection
            self?.onFinished?(selection)
        }
    }
}

/// A thread with its own run loop that runs blocks in order, always on itself.
final class CaptureSessionThread: Thread, @unchecked Sendable {
    /// One for the app: the session and the preview layers attached to it must all be
    /// started, stopped and detached here, in order.
    static let shared = CaptureSessionThread()

    private final class Job: NSObject {
        let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
    }

    override init() {
        super.init()
        name = "com.giusscos.yprompt.mac-capture"
        qualityOfService = .userInitiated
        start()
    }

    override func main() {
        // A port keeps the run loop alive while there's nothing to do.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        while !isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    /// Runs `block` on this thread after anything already queued.
    func run(_ block: @escaping () -> Void) {
        perform(#selector(execute(_:)), on: self, with: Job(block), waitUntilDone: false)
    }

    @objc private func execute(_ job: Job) {
        job.block()
    }
}
#endif
