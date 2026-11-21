//
//  ScriptIntents.swift
//  yprompt
//

import AppIntents
import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - Writing scripts

struct CreateScriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Script"
    static let description = IntentDescription(
        "Adds a new script to yPrompt, for example with text another action has written.",
        categoryName: "Scripts"
    )

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Create \(\.$title) with \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScriptEntity> {
        let script = try await AppDataStore.makeScript(title: title, text: text)
        return .result(value: ScriptEntity(script))
    }
}

struct AppendToScriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Text to Script"
    static let description = IntentDescription("Adds text at the end of a script.", categoryName: "Scripts")

    @Parameter(title: "Script")
    var script: ScriptEntity

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$script)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScriptEntity> {
        guard let stored = AppDataStore.script(id: script.id) else { throw ScriptIntentError.notFound }
        try AppDataStore.append(text, to: stored)
        return .result(value: ScriptEntity(stored))
    }
}

struct ReplaceScriptTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Replace Script Text"
    static let description = IntentDescription(
        "Replaces everything a script says, for example with a rewritten version.",
        categoryName: "Scripts"
    )

    @Parameter(title: "Script")
    var script: ScriptEntity

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Replace the text of \(\.$script) with \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScriptEntity> {
        guard let stored = AppDataStore.script(id: script.id) else { throw ScriptIntentError.notFound }
        try AppDataStore.setText(of: stored, to: text)
        return .result(value: ScriptEntity(stored))
    }
}

struct GetScriptTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Script Text"
    static let description = IntentDescription(
        "Gives a script's text to the next action, for example to shorten or translate it.",
        categoryName: "Scripts"
    )

    @Parameter(title: "Script")
    var script: ScriptEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the text of \(\.$script)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let stored = AppDataStore.script(id: script.id) else { throw ScriptIntentError.notFound }
        return .result(value: stored.content)
    }
}

// MARK: - Opening and reading

struct OpenScriptIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Script"
    static let description = IntentDescription("Opens a script in the editor.", categoryName: "Scripts")

    @Parameter(title: "Script")
    var target: ScriptEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard AppDataStore.script(id: target.id) != nil else { throw ScriptIntentError.notFound }
        AppRouter.shared.open(.editor(scriptID: target.id))
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
        return .result()
    }
}

/// What to record while reading.
enum RecordingKind: String, AppEnum {
    case camera, audio

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Recording")
    static let caseDisplayRepresentations: [RecordingKind: DisplayRepresentation] = [
        .camera: DisplayRepresentation(title: "Camera", image: .init(systemName: "video.fill")),
        .audio: DisplayRepresentation(title: "Audio Only", image: .init(systemName: "mic.fill")),
    ]
}

struct StartTeleprompterIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Teleprompter"
    static let description = IntentDescription(
        "Shows a script in the teleprompter, ready to read, optionally with the camera or microphone on.",
        categoryName: "Reading"
    )
    // The Mac reads in a floating window or the notch, over other apps; the iPhone and iPad
    // read full screen, so the app comes forward there.
    #if os(macOS)
    static let openAppWhenRun = false
    #else
    static let openAppWhenRun = true
    #endif

    @Parameter(title: "Script")
    var script: ScriptEntity

    @Parameter(title: "Recording", description: "Turn on the camera or microphone, ready to record.")
    var recording: RecordingKind?

    static var parameterSummary: some ParameterSummary {
        Summary("Start the teleprompter with \(\.$script)") {
            \.$recording
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let stored = AppDataStore.script(id: script.id) else { throw ScriptIntentError.notFound }
        Reader.present(stored, recording: recording)
        return .result(dialog: "\(stored.title) is ready to read.")
    }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record While Reading"
    static let description = IntentDescription(
        "Opens a script in the teleprompter and records you reading it. The camera gets ready and you start the take.",
        categoryName: "Reading"
    )
    #if os(macOS)
    static let openAppWhenRun = false
    #else
    static let openAppWhenRun = true
    #endif

    @Parameter(title: "Script")
    var script: ScriptEntity

    @Parameter(title: "Recording", default: .camera)
    var recording: RecordingKind

    static var parameterSummary: some ParameterSummary {
        Summary("Record \(\.$script) with \(\.$recording)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let stored = AppDataStore.script(id: script.id) else { throw ScriptIntentError.notFound }
        Reader.present(stored, recording: recording)
        #if os(macOS)
        // The prompter and the take start together, as with the record button.
        FloatingTeleprompterManager.shared.toggleRecording()
        return .result(dialog: "Recording \(stored.title).")
        #else
        return .result(dialog: "Tap record when you're ready.")
        #endif
    }
}

#if os(macOS)
struct StopTeleprompterIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Teleprompter"
    static let description = IntentDescription(
        "Closes the teleprompter. A take being recorded is finished and saved.",
        categoryName: "Reading"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        FloatingTeleprompterManager.shared.hide()
        return .result()
    }
}
#endif

// MARK: - Shared

enum ScriptIntentError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "That script isn't in yPrompt anymore.")
        }
    }
}

/// Starts reading, the same way on every path: the menu bar, the editor, or an intent.
@MainActor
enum Reader {
    static func present(_ script: Script, recording: RecordingKind?) {
        #if os(macOS)
        let manager = FloatingTeleprompterManager.shared
        if let recording {
            manager.recordMode = recording == .camera ? .camera : .audio
        }
        manager.show(script: script, storeKit: StoreKitService.shared)
        #else
        if let recording {
            UserDefaults.standard.set(recording == .camera ? ReadingPreferences.cameraBackground
                                                           : ReadingPreferences.audioBackground,
                                      forKey: ReadingPreferences.backgroundKey)
        }
        AppRouter.shared.open(.teleprompter(scriptID: script.id))
        #endif
    }
}
