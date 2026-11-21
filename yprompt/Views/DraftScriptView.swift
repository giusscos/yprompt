//
//  DraftScriptView.swift
//  yprompt
//

import SwiftUI

/// Writes a first draft with Apple Intelligence, on the device: say what it's about, how long
/// and in what tone, then read it over and add it as a script.
struct DraftScriptView: View {
    let onCreated: (Script) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var minutes = 2.0
    @State private var tone: ScriptTone = .conversational
    @State private var stage: Stage = .compose
    @State private var title = ""
    @State private var text = ""
    @State private var task: Task<Void, Never>?
    @FocusState private var topicFocused: Bool
    @FocusState private var scriptFocused: Bool

    private enum Stage: Equatable {
        case compose, writing, review
        case failed(String)
    }

    private static let lengths: [Double] = [0.5, 1, 2, 3, 5]

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .compose, .failed: composeForm
                case .writing: writingView
                case .review: reviewForm
                }
            }
            .navigationTitle("Write Script")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            #if os(macOS)
            // Otherwise the Mac selects the whole title, as the first field.
            .onChange(of: stage) { _, stage in if stage == .review { scriptFocused = true } }
            #endif
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        #endif
        .onDisappear { task?.cancel() }
        #if DEBUG
        .onAppear(perform: showSampleDraftForScreenshots)
        #endif
    }

    #if DEBUG
    /// For App Store screenshots: the Simulator's model doesn't answer, so a written draft is shown.
    private func showSampleDraftForScreenshots() {
        guard ProcessInfo.processInfo.arguments.contains("-ypShotDraft") else { return }
        topic = "Episode 12 of my cooking podcast, about knife skills"
        title = "Knife Skills for Every Cook"
        text = """
            Welcome back to episode twelve. Today we're talking about the one tool you use every time you cook: your knife.

            Good knife skills make cooking faster, safer and a lot more fun. And you don't need a drawer full of gadgets. One sharp chef's knife will do almost everything.

            Let's start with the grip. Pinch the blade just above the handle, between your thumb and your index finger. It feels strange at first, but it gives you far more control.

            Now the other hand. Curl your fingertips under, like a claw, and let your knuckles guide the side of the blade. Your fingers stay safely out of the way.

            Here's a practical tip: keep your knife sharp. A dull knife slips, and slipping is how most kitchen cuts happen.
            """
        stage = .review
        #if os(macOS)
        Task { scriptFocused = true }
        #endif
    }
    #endif

    // MARK: Compose

    private var composeForm: some View {
        Form {
            // At the top, where it's seen even with the keyboard up.
            if case .failed(let message) = stage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextField("What's it about?", text: $topic, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($topicFocused)
                    .onAppear { topicFocused = true }
            } header: {
                Text("Topic")
            } footer: {
                Text("For example: “Welcome to episode 12 of my cooking podcast, about knife skills.”")
            }

            Section("Length") {
                Picker("Length", selection: $minutes) {
                    ForEach(Self.lengths, id: \.self) { value in
                        Text(lengthLabel(value)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Tone") {
                Picker("Tone", selection: $tone) {
                    ForEach(ScriptTone.allCases) { tone in
                        Text(tone.title).tag(tone)
                    }
                }
                #if os(iOS)
                .pickerStyle(.menu)
                #endif
                .labelsHidden()
            }

            Section {
            } footer: {
                Text("Written on this device with Apple Intelligence. Nothing you type leaves it. Check facts and names before you read it out.")
            }
        }
        .formStyle(.grouped)
    }

    private func lengthLabel(_ value: Double) -> String {
        value < 1 ? String(localized: "30 sec") : String(localized: "\(Int(value)) min")
    }

    // MARK: Writing

    private var writingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Writing your script…")
                .font(.headline)
            Text("This takes a few seconds.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Review

    private var reviewForm: some View {
        Form {
            Section("Title") {
                TextField("Title", text: $title)
                    // The section already says it; on the Mac the field would repeat it.
                    .labelsHidden()
            }
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 260)
                    .font(.body)
                    .focused($scriptFocused)
            } header: {
                Text("Script")
            } footer: {
                let words = text.split(whereSeparator: \.isWhitespace).count
                Text("\(words) words · about \(max(1, Int((Double(words) / ScriptWriter.wordsPerMinute).rounded()))) min")
            }
            Section {
                Button { write() } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        switch stage {
        case .compose, .failed:
            ToolbarItem(placement: .confirmationAction) {
                Button("Write") { write() }
                    .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .writing:
            ToolbarItem(placement: .confirmationAction) {
                Button("Write") {}.disabled(true)
            }
        case .review:
            ToolbarItem(placement: .confirmationAction) {
                Button("Add Script") { add() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: Actions

    private func write() {
        stage = .writing
        let topic = topic, minutes = minutes, tone = tone
        task = Task {
            do {
                let draft = try await ScriptWriter.draft(topic: topic, minutes: minutes, tone: tone)
                guard !Task.isCancelled else { return }
                title = draft.title
                text = draft.text
                stage = .review
            } catch {
                guard !Task.isCancelled else { return }
                stage = .failed(error.localizedDescription)
            }
        }
    }

    private func add() {
        Task {
            do {
                let script = try await AppDataStore.makeScript(title: title, text: text)
                dismiss()
                onCreated(script)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}
