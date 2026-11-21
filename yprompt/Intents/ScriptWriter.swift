//
//  ScriptWriter.swift
//  yprompt
//

import AppIntents
import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// How a drafted script should sound.
enum ScriptTone: String, AppEnum, CaseIterable, Identifiable {
    case conversational, professional, energetic, inspiring, funny

    var id: String { rawValue }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tone")
    static let caseDisplayRepresentations: [ScriptTone: DisplayRepresentation] = [
        .conversational: "Conversational",
        .professional: "Professional",
        .energetic: "Energetic",
        .inspiring: "Inspiring",
        .funny: "Funny",
    ]

    var title: LocalizedStringResource {
        Self.caseDisplayRepresentations[self]?.title ?? "Conversational"
    }

    /// How the model is told, in English, which it follows best.
    fileprivate var instruction: String {
        switch self {
        case .conversational: "warm and conversational, like talking to one person"
        case .professional: "clear, confident and professional"
        case .energetic: "upbeat and energetic"
        case .inspiring: "inspiring and heartfelt"
        case .funny: "light and funny, with gentle humour"
        }
    }
}

/// Writes and shortens scripts with Apple Intelligence, on the device. Nothing leaves it.
@MainActor
enum ScriptWriter {
    /// Spoken pace used everywhere in the app for reading time.
    static let wordsPerMinute = 130.0

    enum WriterError: LocalizedError {
        case unavailable(String)
        case tooLong
        case declined
        case failed

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .tooLong: String(localized: "This script is too long for Apple Intelligence to rewrite in one go. Try a part of it.")
            case .declined: String(localized: "Apple Intelligence couldn't write about this topic. Try wording it differently.")
            case .failed: String(localized: "Apple Intelligence couldn't finish the script. Please try again.")
            }
        }
    }

    /// True when Apple Intelligence is on and ready on this device.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Why it can't be used right now, in words for the person.
    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return ""
            case .unavailable(.appleIntelligenceNotEnabled):
                return String(localized: "Turn on Apple Intelligence in Settings to write scripts with it.")
            case .unavailable(.modelNotReady):
                return String(localized: "Apple Intelligence is still getting ready. Try again in a little while.")
            case .unavailable(.deviceNotEligible):
                return String(localized: "This device doesn't support Apple Intelligence.")
            case .unavailable:
                return String(localized: "Apple Intelligence isn't available right now.")
            }
        }
        #endif
        return String(localized: "Writing scripts with Apple Intelligence needs a newer version of the system.")
    }

    private static let instructions = """
        You write scripts that a person reads aloud from a teleprompter, for videos, talks and podcasts.
        Write only the words to be spoken: no stage directions, no headings, no lists, no markdown, no emoji.
        Use short sentences and short paragraphs, with a blank line between paragraphs.
        Write in the same language as the topic or text you are given.
        """

    /// A new script about `topic`, roughly `minutes` long when read aloud.
    static func draft(topic: String, minutes: Double, tone: ScriptTone) async throws -> (title: String, text: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { throw WriterError.unavailable(unavailableReason) }
            let words = Int(minutes * wordsPerMinute)
            let session = LanguageModelSession(instructions: instructions)
            let prompt = """
                Write a script about this topic: \(topic)
                Tone: \(tone.instruction).
                Length: between \(words) and \(Int(Double(words) * 1.15)) words, which is \(formatted(minutes)) when spoken. Do not write fewer than \(words) words.
                Break it into paragraphs of two to four sentences.
                """
            do {
                let draft = try await session.respond(to: prompt, generating: GeneratedScript.self).content
                var text = draft.text
                // The model tends to write short. Once, ask it to bring the draft up to length.
                let written = text.split(whereSeparator: \.isWhitespace).count
                if Double(written) < Double(words) * 0.8 {
                    // Structured again: asked for plain text, it copies the first answer's format.
                    let longer = try? await session.respond(to: """
                        That is \(written) words; it needs to be about \(words). Rewrite the whole script \
                        at about \(words) words: keep the opening and the closing, and add detail, examples \
                        and one practical tip in the middle.
                        """, generating: GeneratedScript.self).content.text
                    if let longer, longer.split(whereSeparator: \.isWhitespace).count > written {
                        text = longer
                    }
                }
                return (draft.title.trimmingCharacters(in: .whitespacesAndNewlines), tidy(text))
            } catch {
                throw map(error)
            }
        }
        #endif
        throw WriterError.unavailable(unavailableReason)
    }

    /// `text` rewritten to read in about `minutes`, keeping what it says.
    static func fit(_ text: String, minutes: Double) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { throw WriterError.unavailable(unavailableReason) }
            let words = Int(minutes * wordsPerMinute)
            let session = LanguageModelSession(instructions: instructions)
            let prompt = """
                Rewrite this script so it is about \(words) words long (\(formatted(minutes)) when spoken).
                Keep its meaning, its key points and its voice. Return only the rewritten script.

                \(text)
                """
            do {
                return tidy(try await session.respond(to: prompt).content)
            } catch {
                throw map(error)
            }
        }
        #endif
        throw WriterError.unavailable(unavailableReason)
    }

    private static func formatted(_ minutes: Double) -> String {
        let seconds = Int((minutes * 60).rounded())
        return seconds % 60 == 0 ? "\(seconds / 60) minutes" : "\(seconds / 60) minutes \(seconds % 60) seconds"
    }

    /// Removes what doesn't belong on a teleprompter, should the model add it anyway, and
    /// breaks one long block into short paragraphs, which are easier to read aloud.
    private static func tidy(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.contains("\n\n") else { return cleaned }
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleaned
        tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            sentences.append(cleaned[range].trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        }
        guard sentences.count > 3 else { return cleaned }
        return stride(from: 0, to: sentences.count, by: 3)
            .map { sentences[$0..<min($0 + 3, sentences.count)].joined(separator: " ") }
            .joined(separator: "\n\n")
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func map(_ error: Error) -> WriterError {
        guard let error = error as? LanguageModelSession.GenerationError else { return .failed }
        switch error {
        case .exceededContextWindowSize: return .tooLong
        case .guardrailViolation, .refusal: return .declined
        default: return .failed
        }
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct GeneratedScript {
    @Guide(description: "A short title for the script, at most six words")
    var title: String

    @Guide(description: "The full script, exactly the words to be spoken, in short paragraphs separated by blank lines")
    var text: String
}
#endif

// MARK: - Intents

struct DraftScriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Write Script with Apple Intelligence"
    static let description = IntentDescription(
        "Writes a new script on your device with Apple Intelligence and adds it to yPrompt.",
        categoryName: "Scripts"
    )

    @Parameter(title: "Topic", inputOptions: String.IntentInputOptions(multiline: true))
    var topic: String

    @Parameter(title: "Length (minutes)", default: 2, inclusiveRange: (0.5, 5))
    var minutes: Double

    @Parameter(title: "Tone", default: .conversational)
    var tone: ScriptTone

    static var parameterSummary: some ParameterSummary {
        Summary("Write a \(\.$minutes) minute script about \(\.$topic)") {
            \.$tone
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScriptEntity> & ProvidesDialog {
        let draft = try await ScriptWriter.draft(topic: topic, minutes: minutes, tone: tone)
        let script = try await AppDataStore.makeScript(title: draft.title, text: draft.text)
        return .result(value: ScriptEntity(script), dialog: "\(script.title) is in yPrompt.")
    }
}

struct FitScriptToTimeIntent: AppIntent {
    static let title: LocalizedStringResource = "Fit Script to Time"
    static let description = IntentDescription(
        "Rewrites a script with Apple Intelligence, on your device, so it reads in the time you choose. The original is kept as a copy.",
        categoryName: "Scripts"
    )

    @Parameter(title: "Script")
    var script: ScriptEntity

    @Parameter(title: "Length (minutes)", default: 1, inclusiveRange: (0.5, 10))
    var minutes: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Fit \(\.$script) to \(\.$minutes) minutes")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScriptEntity> & ProvidesDialog {
        guard let stored = AppDataStore.script(id: script.id) else { throw ScriptIntentError.notFound }
        let fitted = try await ScriptWriter.fit(stored.content, minutes: minutes)
        let title = String(localized: "\(stored.title) (\(Int(minutes.rounded())) min)")
        let copy = try await AppDataStore.makeScript(title: title, text: fitted)
        return .result(value: ScriptEntity(copy), dialog: "\(copy.title) is in yPrompt.")
    }
}
