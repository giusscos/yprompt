//
//  RecordingsListView.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import SwiftData
import SwiftUI

/// Every recording on this iPhone, newest first, ready to open in the editor.
struct RecordingsListView: View {
    @Environment(StoreKitService.self) private var storeKit
    @Query private var scripts: [Script]
    @State private var library = RecordingLibrary.shared
    @State private var opened: RecordingSelection?
    @State private var route: PickupRoute?
    @State private var deleting: Recording?
    @State private var thumbnails: [UUID: CGImage] = [:]

    /// Recording more from the tab opens the reading screen for the recording's script.
    struct PickupRoute: Hashable {
        let script: Script
        let pickup: Pickup
    }

    var body: some View {
        Group {
            if library.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings Yet", systemImage: "film.stack")
                } description: {
                    Text("Open a script and choose Camera or Audio Only to record. Every take lands here, ready to edit.")
                }
            } else {
                list
            }
        }
        .navigationTitle("Recordings")
        .task {
            await library.load()
            #if DEBUG
            await seedForScreenshots()
            #endif
        }
        .task(id: library.recordings.map(\.id)) { await loadThumbnails() }
        .fullScreenCover(item: $opened) { selection in
            let script = scriptFor(selection.recordingID)
            RecordingEditorView(
                selection: selection,
                script: script?.scriptWords,
                onRecordMore: script.map { script in
                    { pickup in
                        opened = nil
                        Task { @MainActor in
                            // The editor has to finish closing before the reading screen can open.
                            try? await Task.sleep(for: .milliseconds(400))
                            route = PickupRoute(script: script, pickup: pickup)
                        }
                    }
                },
                onClose: { opened = nil }
            )
            .environment(storeKit)
        }
        .navigationDestination(item: $route) { route in
            TeleprompterView(script: route.script, pickup: route.pickup)
                .environment(storeKit)
        }
        .confirmationDialog("Delete this recording?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { recording in
            Button("Delete Recording", role: .destructive) { library.delete(recording) }
        } message: { recording in
            Text(recording.savedAt == nil
                 ? "It hasn't been saved to Photos. This can't be undone."
                 : "The copy in Photos stays. This can't be undone.")
        }
    }

    private var list: some View {
        List {
            ForEach(sections, id: \.id) { section in
                Section(section.title) {
                    ForEach(section.recordings) { recording in
                        Button { opened = RecordingSelection(recordingID: recording.id) } label: {
                            row(recording)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = recording }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = recording }
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text("Recordings use \(ByteCountFormatter.string(fromByteCount: library.usedBytes, countStyle: .file)) on this device. They aren't backed up, so save the ones you want to keep.")
            }
        }
    }

    private func row(_ recording: Recording) -> some View {
        HStack(spacing: 14) {
            ZStack {
                if recording.kind == .video, let image = thumbnails[recording.id] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.accentColor.opacity(0.15)
                    Image(systemName: recording.kind == .audio ? "waveform" : "video.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Duration.seconds(recording.length), format: .time(pattern: .minuteSecond))
                        .monospacedDigit()
                    if recording.pieces.count > 1 {
                        Text("·")
                        Text("\(recording.pieces.count) pieces")
                    }
                    if recording.kind == .audio {
                        Text("·")
                        Text("Audio")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if recording.savedAt != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Saved to Photos")
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Data

    private struct DaySection {
        let id: String
        let title: LocalizedStringKey
        let recordings: [Recording]
    }

    private var sections: [DaySection] {
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let today = library.recordings.filter { calendar.isDateInToday($0.createdAt) }
        let week = library.recordings.filter { !calendar.isDateInToday($0.createdAt) && $0.createdAt >= weekAgo }
        let earlier = library.recordings.filter { $0.createdAt < weekAgo }
        return [DaySection(id: "today", title: "Today", recordings: today),
                DaySection(id: "week", title: "This Week", recordings: week),
                DaySection(id: "earlier", title: "Earlier", recordings: earlier)]
            .filter { !$0.recordings.isEmpty }
    }

    private func scriptFor(_ recordingID: UUID) -> Script? {
        guard let scriptID = library.recording(recordingID)?.scriptID else { return nil }
        return scripts.first { $0.id == scriptID }
    }

    #if DEBUG
    /// For App Store screenshots. `-ypDemoRecordings <folder>` fills an empty library from the
    /// folder's `manifest.json`; `-ypShotOpenRecording <title>` then opens that recording.
    private func seedForScreenshots() async {
        let defaults = UserDefaults.standard
        if library.recordings.isEmpty, let folder = defaults.string(forKey: "ypDemoRecordings") {
            struct Entry: Decodable {
                var title: String
                var kind: Recording.Kind
                var files: [String]
                var daysAgo: Double
                var saved: Bool?
                var captionStyle: CaptionStyle?
            }
            let base = URL(fileURLWithPath: folder)
            guard let data = try? Data(contentsOf: base.appendingPathComponent("manifest.json")),
                  let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
            for entry in entries {
                let scriptID = scripts.first { $0.title == entry.title }?.id
                var recordingID: UUID?
                for file in entry.files {
                    let target = RecordingTarget(scriptID: scriptID, title: entry.title, recordingID: recordingID)
                    let pending = RecordingStore.beginPiece(target, kind: entry.kind, startProgress: 0)
                    try? FileManager.default.copyItem(at: base.appendingPathComponent(file), to: pending.url)
                    // Word timings made with the demo audio, for simulators whose speech model won't load.
                    try? FileManager.default.copyItem(at: base.appendingPathComponent(file + ".analysis.json"),
                                                      to: pending.url.appendingPathExtension("analysis.json"))
                    guard let (recording, _) = await RecordingStore.finishPiece(pending, endProgress: 1) else { continue }
                    recordingID = recording.id
                }
                guard let recordingID, var recording = RecordingStore.load(recordingID) else { continue }
                recording.createdAt = Date().addingTimeInterval(-entry.daysAgo * 86_400)
                recording.savedAt = entry.saved == true ? Date() : nil
                if let style = entry.captionStyle { recording.captionStyle = style }
                RecordingStore.save(recording)
            }
            library.refresh()
        }
        if let title = defaults.string(forKey: "ypShotOpenRecording"),
           let recording = library.recordings.first(where: { $0.title == title }) {
            let index = defaults.integer(forKey: "ypShotSelectPiece")
            let piece = recording.pieces.indices.contains(index) ? recording.pieces[index].id : nil
            try? await Task.sleep(for: .milliseconds(500))
            opened = RecordingSelection(recordingID: recording.id, pieceID: piece)
        }
    }
    #endif

    private func loadThumbnails() async {
        for recording in library.recordings where recording.kind == .video && thumbnails[recording.id] == nil {
            guard let piece = recording.pieces.first else { continue }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: recording.url(of: piece)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 168, height: 168)
            if let image = try? await generator.image(at: CMTime(seconds: piece.start + 0.05, preferredTimescale: 600)).image {
                thumbnails[recording.id] = image
            }
        }
    }
}
#endif
