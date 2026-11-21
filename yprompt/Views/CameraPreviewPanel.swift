//
//  CameraPreviewPanel.swift
//  yprompt
//

#if os(macOS)
import AVFoundation
import SwiftUI

/// The small floating window that shows the camera while recording from the prompter.
/// It can be moved, resized and hidden; the camera keeps running when it's hidden.
struct CameraPreviewWindowView: View {
    private let manager = FloatingTeleprompterManager.shared
    private var capture: MacCaptureService { manager.capture }
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.black
            if let session = capture.captureSession {
                CameraPreviewLayerView(session: session, movesWindow: true, mirrored: manager.mirrorsCamera)
                    .overlay { DemoCameraPicture() }
            }
        }
        .overlay(alignment: .topLeading) {
            if capture.isRecording, let start = capture.recordingStartDate {
                RecordingBadge(start: start)
                    .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button { manager.showsCameraPreview = false } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Hide Camera Preview")
                .accessibilityLabel("Hide Camera Preview")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip(cornerRadius: 14, isVisible: isHovering, keepsAspectRatio: true) {
                manager.beginPreviewAdjustment()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovering = hovering }
        }
    }
}

/// A red dot and the time recorded so far.
struct RecordingBadge: View {
    let start: Date
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 8, height: 8)
            if !compact {
                TimelineView(.periodic(from: start, by: 1)) { timeline in
                    let total = max(0, Int(timeline.date.timeIntervalSince(start)))
                    Text(String(format: "%02d:%02d", total / 60, total % 60))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, compact ? 0 : 7)
        .padding(.vertical, compact ? 0 : 3)
        .background(compact ? .clear : .black.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording")
    }
}

/// The live camera image, mirrored like a mirror. The recorded file isn't.
struct CameraPreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    /// Dragging the picture moves its window: on in the preview window, off in the notch.
    var movesWindow = false
    var mirrored = true

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.movesWindow = movesWindow
        attach(session, to: view)
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        if view.attachedSession !== session { attach(session, to: view) }
        applyMirroring(to: view)
    }

    /// Like detaching, attaching happens on the capture thread, in order with starts and stops.
    private func attach(_ session: AVCaptureSession, to view: PreviewView) {
        view.attachedSession = session
        let layer = view.previewLayer
        let mirrored = mirrored
        CaptureSessionThread.shared.run {
            layer.session = session
            DispatchQueue.main.async { Self.mirror(layer, mirrored) }
        }
    }

    /// The layer lets go of the session on the capture thread, after any stop queued there.
    /// Done on the main thread, detaching waits for a stopping session, which itself waits for
    /// the main thread: neither would ever finish.
    static func dismantleNSView(_ view: PreviewView, coordinator: ()) {
        let layer = view.previewLayer
        CaptureSessionThread.shared.run { layer.session = nil }
    }

    private func applyMirroring(to view: PreviewView) {
        Self.mirror(view.previewLayer, mirrored)
    }

    private static func mirror(_ layer: AVCaptureVideoPreviewLayer, _ mirrored: Bool) {
        guard let connection = layer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirrored != mirrored { connection.isVideoMirrored = mirrored }
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var movesWindow = false
        /// The session last handed to the layer; the layer itself is updated on the capture thread.
        weak var attachedSession: AVCaptureSession?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            layer = previewLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // The preview window has no title bar: dragging the picture moves it.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { movesWindow }
        override func hitTest(_ point: NSPoint) -> NSView? { movesWindow ? super.hitTest(point) : nil }
        override func mouseDown(with event: NSEvent) {
            FloatingTeleprompterManager.shared.beginPreviewAdjustment()
            window?.performDrag(with: event)
        }
    }
}

/// An area that moves its window when dragged, for windows without a title bar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

// MARK: - Resize grip

/// The corner grip shown on hover, like resizing a window on iPad: an arc hugging the bottom
/// right corner that can be dragged to resize the window.
struct ResizeGrip: View {
    let cornerRadius: CGFloat
    let isVisible: Bool
    var keepsAspectRatio = false
    var onBegin: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CornerArc(cornerRadius: cornerRadius)
                .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .shadow(color: .black.opacity(0.45), radius: 3)
                .frame(width: cornerRadius * 2 + 6, height: cornerRadius * 2 + 6)
                .opacity(isVisible ? 1 : 0)
                .scaleEffect(isVisible ? 1 : 0.6, anchor: .bottomTrailing)
                .allowsHitTesting(false)
            ResizeHandle(keepsAspectRatio: keepsAspectRatio, onBegin: onBegin)
                .frame(width: 34, height: 34)
        }
        .accessibilityHidden(true)
    }
}

/// A quarter circle following a rounded bottom right corner, a little inside it.
private struct CornerArc: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 5
        let radius = max(4, cornerRadius - inset)
        let center = CGPoint(x: rect.maxX - inset - radius, y: rect.maxY - inset - radius)
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(8), endAngle: .degrees(82), clockwise: false)
        return path
    }
}

/// Resizes its window from the bottom right corner, keeping the top left where it is.
private struct ResizeHandle: NSViewRepresentable {
    var keepsAspectRatio: Bool
    var onBegin: (() -> Void)?

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.keepsAspectRatio = keepsAspectRatio
        view.onBegin = onBegin
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.keepsAspectRatio = keepsAspectRatio
        view.onBegin = onBegin
    }

    final class HandleView: NSView {
        var keepsAspectRatio = false
        var onBegin: (() -> Void)?
        private var startFrame = CGRect.zero
        private var startMouse = CGPoint.zero

        private var cursor: NSCursor {
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: .bottomRight, directions: .all)
            }
            return .crosshair
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
                                           owner: self))
        }

        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startFrame = window.frame
            startMouse = NSEvent.mouseLocation
            onBegin?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let mouse = NSEvent.mouseLocation
            var width = startFrame.width + (mouse.x - startMouse.x)
            var height = startFrame.height - (mouse.y - startMouse.y)
            if let limiter = window.delegate as? PanelSizeLimiter {
                (width, height) = { let size = limiter.clamp(CGSize(width: width, height: height)); return (size.width, size.height) }()
            } else {
                width = min(max(width, window.minSize.width), window.maxSize.width)
                if keepsAspectRatio { height = width * 9 / 16 }
                height = min(max(height, window.minSize.height), window.maxSize.height)
                if keepsAspectRatio { width = height * 16 / 9 }
            }
            window.setFrame(CGRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height),
                            display: true)
            cursor.set()
        }
    }
}
#endif

#if os(macOS)
/// For App Store screenshots: with the Demo Camera Background setting on (or launched with
/// `-debug.demoCameraBackground YES`), a photo covers the live picture.
struct DemoCameraPicture: View {
    var body: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: AppConstants.debugDemoCameraKey) {
            GeometryReader { proxy in
                // Portrait photo in a wide frame: cropped high, so the face stays in view.
                let image = NSImage(named: "CameraDemoBackground")
                let size = image?.size ?? CGSize(width: 3, height: 4)
                let scale = max(proxy.size.width / size.width, proxy.size.height / size.height)
                let height = size.height * scale
                let offset = min(0, max(proxy.size.height - height, -height * 0.12))
                Image("CameraDemoBackground")
                    .resizable()
                    .frame(width: size.width * scale, height: height)
                    .offset(x: (proxy.size.width - size.width * scale) / 2, y: offset)
            }
            .clipped()
            .allowsHitTesting(false)
        }
        #endif
    }
}
#endif
