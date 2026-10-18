//
//  CameraRecordingService.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import Combine
import Photos

/// One physical lens behind a (possibly virtual) capture device, e.g. "0.5×" or "1×".
struct CameraLens: Identifiable, Hashable {
    let id: String
    let label: String
    /// The device `videoZoomFactor` that switches to this lens.
    let zoomFactor: CGFloat
}

enum VideoResolution: String, CaseIterable, Identifiable {
    case hd1080 = "1080p"
    case uhd4K = "4K"

    var id: String { rawValue }

    var dimensions: CMVideoDimensions {
        switch self {
        case .hd1080: return CMVideoDimensions(width: 1920, height: 1080)
        case .uhd4K:  return CMVideoDimensions(width: 3840, height: 2160)
        }
    }
}

enum VideoStabilization: String, CaseIterable, Identifiable {
    case off = "Off"
    case standard = "Standard"
    case cinematic = "Cinematic"

    var id: String { rawValue }

    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off:       return .off
        case .standard:  return .standard
        case .cinematic: return .cinematic
        }
    }
}

@MainActor
final class CameraRecordingService: NSObject, ObservableObject {
    static let frameRateOptions = [24, 30, 60]

    @Published var isCameraActive = false
    @Published var isRecording = false
    @Published var permissionDenied = false
    @Published var recordingSaved = false
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .front

    // Lens & zoom
    @Published private(set) var lenses: [CameraLens] = []
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    /// Device zoom factor shown to the user as "1×" (the main wide lens).
    @Published private(set) var baselineZoom: CGFloat = 1

    // Format
    @Published private(set) var resolution: VideoResolution
    @Published private(set) var frameRate: Int
    @Published private(set) var stabilization: VideoStabilization
    @Published private(set) var supportedResolutions: [VideoResolution] = []
    @Published private(set) var supportedFrameRates: [Int] = []
    @Published private(set) var supportedStabilizations: [VideoStabilization] = [.off]

    // Exposure, focus, light
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureBiasRange: ClosedRange<Float> = 0...0
    @Published private(set) var isFocusExposureLocked = false
    @Published private(set) var hasTorch = false
    @Published private(set) var isTorchOn = false

    private(set) var captureSession: AVCaptureSession?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var videoInput: AVCaptureDeviceInput?
    private var videoDevice: AVCaptureDevice? { videoInput?.device }

    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []

    private enum DefaultsKey {
        static let resolution = "camera.resolution"
        static let frameRate = "camera.frameRate"
        static let stabilization = "camera.stabilization"
    }

    override init() {
        let defaults = UserDefaults.standard
        resolution = VideoResolution(rawValue: defaults.string(forKey: DefaultsKey.resolution) ?? "") ?? .hd1080
        let savedRate = defaults.integer(forKey: DefaultsKey.frameRate)
        frameRate = Self.frameRateOptions.contains(savedRate) ? savedRate : 30
        stabilization = VideoStabilization(rawValue: defaults.string(forKey: DefaultsKey.stabilization) ?? "") ?? .standard
        super.init()
    }

    /// True when the device has a camera on the other side to switch to.
    var canSwitchCamera: Bool {
        Self.videoDevice(for: .front) != nil && Self.videoDevice(for: .back) != nil
    }

    /// Zoom as the user reads it, relative to the main lens (0.5×, 1×, 2×…).
    var displayZoom: CGFloat { zoomFactor / baselineZoom }

    func requestPermissionsAndStart() async {
        var cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            cameraGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            micGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        }

        guard cameraGranted && micGranted else {
            permissionDenied = true
            return
        }

        startCamera()
    }

    func startCamera() {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let camera = Self.videoDevice(for: cameraPosition),
            let cameraInput = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(cameraInput)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(cameraInput)
        videoInput = cameraInput

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

        configureCurrentDevice()
        session.commitConfiguration()
        captureSession = session
        isCameraActive = true
        rebuildRotationCoordinator()

        Task.detached(priority: .userInitiated) { [session] in
            session.startRunning()
        }
    }

    /// Swaps between the front and back camera, keeping the running session.
    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = cameraPosition == .front ? .back : .front
        guard let session = captureSession else {
            cameraPosition = newPosition
            return
        }
        guard !isRecording,
              let camera = Self.videoDevice(for: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: camera)
        else { return }

        setTorch(false)
        session.beginConfiguration()
        if let videoInput { session.removeInput(videoInput) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoInput = newInput
            cameraPosition = newPosition
        } else if let videoInput {
            session.addInput(videoInput)
        }
        configureCurrentDevice()
        session.commitConfiguration()
        rebuildRotationCoordinator()
    }

    func stopCamera() {
        if isRecording { movieOutput?.stopRecording() }
        let session = captureSession
        captureSession = nil
        isCameraActive = false
        isRecording = false
        isTorchOn = false
        movieOutput = nil
        videoInput = nil
        rotationObservations = []
        rotationCoordinator = nil
        Task.detached(priority: .userInitiated) {
            session?.stopRunning()
        }
    }

    func toggleRecording() {
        if isRecording {
            movieOutput?.stopRecording()
        } else {
            guard let output = movieOutput, !output.isRecording else { return }
            // Lock the file's orientation to how the device is held right now.
            if let coordinator = rotationCoordinator,
               let connection = output.connection(with: .video) {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            output.startRecording(to: url, recordingDelegate: self)
            isRecording = true
        }
    }

    // MARK: - Preview

    /// Called by the preview view so preview and recording rotation follow the device.
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        guard previewLayer !== layer else { return }
        previewLayer = layer
        rebuildRotationCoordinator()
    }

    private func rebuildRotationCoordinator() {
        rotationObservations = []
        guard let device = videoDevice else {
            rotationCoordinator = nil
            return
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                Task { @MainActor in self?.applyPreviewRotation(angle) }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                Task { @MainActor in self?.applyCaptureRotation(angle) }
            },
        ]
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func applyCaptureRotation(_ angle: CGFloat) {
        // A file's orientation can't change mid-recording; it's re-read when the next one starts.
        guard !isRecording,
              let connection = movieOutput?.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    // MARK: - Lens & zoom

    func selectLens(_ lens: CameraLens) {
        setZoom(lens.zoomFactor, animated: true)
    }

    func setZoom(_ factor: CGFloat, animated: Bool = false) {
        guard let device = videoDevice else { return }
        let clamped = min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
        withLockedDevice(device) {
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 12)
            } else {
                device.videoZoomFactor = clamped
            }
        }
        zoomFactor = clamped
    }

    // MARK: - Format

    func setResolution(_ value: VideoResolution) {
        resolution = value
        UserDefaults.standard.set(value.rawValue, forKey: DefaultsKey.resolution)
        reapplyFormat()
    }

    func setFrameRate(_ value: Int) {
        frameRate = value
        UserDefaults.standard.set(value, forKey: DefaultsKey.frameRate)
        reapplyFormat()
    }

    func setStabilization(_ value: VideoStabilization) {
        stabilization = value
        UserDefaults.standard.set(value.rawValue, forKey: DefaultsKey.stabilization)
        applyStabilization()
    }

    private func reapplyFormat() {
        guard !isRecording, let session = captureSession, let device = videoDevice else { return }
        session.beginConfiguration()
        applyFormat(to: device)
        session.commitConfiguration()
        applyStabilization()
    }

    // MARK: - Exposure, focus, torch

    func setExposureBias(_ bias: Float) {
        guard let device = videoDevice else { return }
        let clamped = min(max(bias, exposureBiasRange.lowerBound), exposureBiasRange.upperBound)
        withLockedDevice(device) { device.setExposureTargetBias(clamped) }
        exposureBias = clamped
    }

    /// Holds focus and exposure so they don't hunt while the speaker moves.
    func setFocusExposureLocked(_ locked: Bool) {
        guard let device = videoDevice else { return }
        withLockedDevice(device) {
            let focus: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
            if device.isFocusModeSupported(focus) { device.focusMode = focus }
            let exposure: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
            if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
        }
        isFocusExposureLocked = locked
    }

    func setTorch(_ on: Bool) {
        guard let device = videoDevice, device.hasTorch, device.isTorchModeSupported(on ? .on : .off) else {
            isTorchOn = false
            return
        }
        withLockedDevice(device) { device.torchMode = on ? .on : .off }
        isTorchOn = on
    }

    // MARK: - Device configuration

    /// Back: the widest virtual device available, so all lenses are reachable by zoom.
    private static func videoDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices
        for type in types {
            if let device = devices.first(where: { $0.deviceType == type }) { return device }
        }
        return nil
    }

    /// Lenses, format, zoom and exposure for a freshly attached device. Call inside a session configuration.
    private func configureCurrentDevice() {
        guard let device = videoDevice else { return }
        loadLenses(for: device)
        applyFormat(to: device)

        zoomRange = device.minAvailableVideoZoomFactor...min(device.maxAvailableVideoZoomFactor, baselineZoom * 10)
        withLockedDevice(device) {
            device.videoZoomFactor = min(max(baselineZoom, zoomRange.lowerBound), zoomRange.upperBound)
            device.setExposureTargetBias(0)
        }
        zoomFactor = device.videoZoomFactor
        exposureBias = 0
        exposureBiasRange = max(device.minExposureTargetBias, -3)...min(device.maxExposureTargetBias, 3)
        isFocusExposureLocked = false
        hasTorch = device.hasTorch && device.isTorchModeSupported(.on)
        isTorchOn = false
        applyStabilization()
    }

    private func loadLenses(for device: AVCaptureDevice) {
        let constituents = device.isVirtualDevice ? device.constituentDevices : [device]
        let switchOvers = device.isVirtualDevice
            ? device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            : []
        let factors = [CGFloat(1)] + switchOvers
        let wideIndex = constituents.firstIndex { $0.deviceType == .builtInWideAngleCamera } ?? 0
        baselineZoom = factors.indices.contains(wideIndex) ? factors[wideIndex] : 1

        lenses = zip(constituents, factors).map { lens, factor in
            CameraLens(
                id: lens.deviceType.rawValue,
                label: Self.zoomLabel(factor / baselineZoom),
                zoomFactor: factor
            )
        }
    }

    static func zoomLabel(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f×", rounded)
            : String(format: "%.1f×", rounded)
    }

    private func applyFormat(to device: AVCaptureDevice) {
        let formats = device.formats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        func matches(_ format: AVCaptureDevice.Format, _ res: VideoResolution) -> Bool {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == res.dimensions.width && dims.height == res.dimensions.height
        }
        func supports(_ format: AVCaptureDevice.Format, fps: Int) -> Bool {
            format.videoSupportedFrameRateRanges.contains { Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate }
        }

        supportedResolutions = VideoResolution.allCases.filter { res in formats.contains { matches($0, res) } }
        if !supportedResolutions.contains(resolution) { resolution = supportedResolutions.first ?? .hd1080 }

        let resFormats = formats.filter { matches($0, resolution) }
        supportedFrameRates = Self.frameRateOptions.filter { fps in resFormats.contains { supports($0, fps: fps) } }
        if !supportedFrameRates.contains(frameRate) { frameRate = supportedFrameRates.last(where: { $0 <= 30 }) ?? supportedFrameRates.first ?? 30 }

        // Prefer a format that can do the chosen stabilization, then any that does the frame rate.
        let candidates = resFormats.filter { supports($0, fps: frameRate) }
        guard let format = candidates.first(where: { $0.isVideoStabilizationModeSupported(stabilization.mode) }) ?? candidates.first else {
            return
        }
        withLockedDevice(device) {
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        supportedStabilizations = VideoStabilization.allCases.filter {
            $0 == .off || format.isVideoStabilizationModeSupported($0.mode)
        }
    }

    private func applyStabilization() {
        guard let connection = movieOutput?.connection(with: .video), connection.isVideoStabilizationSupported else { return }
        if !supportedStabilizations.contains(stabilization) { stabilization = supportedStabilizations.last ?? .off }
        connection.preferredVideoStabilizationMode = stabilization.mode
    }

    private func withLockedDevice(_ device: AVCaptureDevice, _ body: () -> Void) {
        do {
            try device.lockForConfiguration()
            body()
            device.unlockForConfiguration()
        } catch {
            print("[Camera] lockForConfiguration failed: \(error)")
        }
    }

    private func saveToPhotoLibrary(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { [weak self] success, _ in
                Task { @MainActor [weak self] in
                    if success { self?.recordingSaved = true }
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}

extension CameraRecordingService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.isRecording = false
            if error == nil {
                self?.saveToPhotoLibrary(url: outputFileURL)
            }
            // Catch up with any rotation that happened while recording.
            if let angle = self?.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture {
                self?.applyCaptureRotation(angle)
            }
        }
    }
}
#endif
