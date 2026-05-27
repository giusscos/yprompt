//
//  CameraRecordingService.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import Combine
import Photos

@MainActor
final class CameraRecordingService: NSObject, ObservableObject {
    @Published var isCameraActive = false
    @Published var isRecording = false
    @Published var permissionDenied = false
    @Published var recordingSaved = false

    private(set) var captureSession: AVCaptureSession?
    private var movieOutput: AVCaptureMovieFileOutput?

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
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let cameraInput = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(cameraInput)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(cameraInput)

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
        captureSession = session
        isCameraActive = true

        Task.detached(priority: .userInitiated) { [session] in
            session.startRunning()
        }
    }

    func stopCamera() {
        if isRecording { movieOutput?.stopRecording() }
        let session = captureSession
        captureSession = nil
        isCameraActive = false
        isRecording = false
        movieOutput = nil
        Task.detached(priority: .userInitiated) {
            session?.stopRunning()
        }
    }

    func toggleRecording() {
        if isRecording {
            movieOutput?.stopRecording()
        } else {
            guard let output = movieOutput, !output.isRecording else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            output.startRecording(to: url, recordingDelegate: self)
            isRecording = true
        }
    }

    private func saveToPhotoLibrary(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, _ in
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
        }
    }
}
#endif
