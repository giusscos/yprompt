//
//  YPTips.swift
//  yprompt
//

import SwiftUI
import TipKit

/// What the tips know about the reader. Kept up to date by `ContentView`.
enum TipState {
    /// Pro or a Pro trial: tips point at Pro tools. Otherwise they point at free ones,
    /// with a gentle word about the trial where a Pro tool is the next step.
    @Parameter static var isPro: Bool = false

    static let scriptCreated = Tips.Event(id: "yp.scriptCreated")
    static let readFinished = Tips.Event(id: "yp.readFinished")
    /// The reading screen opened. Most people stop before the end of a script, so the
    /// reading tips step forward on opens rather than on finished reads.
    static let playerOpened = Tips.Event(id: "yp.playerOpened")
    static let editorOpened = Tips.Event(id: "yp.editorOpened")

    static func configure() {
        #if DEBUG
        // `-ypResetTips` shows every tip again.
        if ProcessInfo.processInfo.arguments.contains("-ypResetTips") { try? Tips.resetDatastore() }
        // App Store screenshots stay free of tips.
        if ProcessInfo.processInfo.arguments.contains("-ypDemoStore") { Tips.hideAllTipsForTesting() }
        #endif
        try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
    }
}

// MARK: - Scripts

/// On New Script, until the first script of one's own is made.
struct NewScriptTip: Tip {
    var title: Text { Text("Add Your First Script") }
    var message: Text? { Text("Type or paste your text, or import a file. Then press play.") }
    var image: Image? { Image(systemName: "plus.circle.fill") }
    var rules: [Rule] {
        #Rule(TipState.scriptCreated) { $0.donations.count == 0 }
    }
}

// MARK: - Reading (iPhone and iPad)

/// Pro, first read: Voice is what Pro is about.
struct VoiceScrollProTip: Tip {
    var title: Text { Text("Let Your Voice Lead") }
    var message: Text? { Text("Choose Voice: the script follows your words and waits when you pause.") }
    var image: Image? { Image(systemName: "mic.fill") }
    var rules: [Rule] {
        #Rule(TipState.$isPro) { $0 == true }
    }
}

/// Free, from the fourth time in the reading screen: by then reading on its own is familiar.
struct VoiceScrollFreeTip: Tip {
    var title: Text { Text("Try Voice Scroll") }
    var message: Text? { Text("With Voice, the script follows your words. It's part of Pro, and you can try it free.") }
    var image: Image? { Image(systemName: "mic.fill") }
    var rules: [Rule] {
        #Rule(TipState.$isPro) { $0 == false }
        #Rule(TipState.playerOpened) { $0.donations.count >= 4 }
    }
}

/// Everyone, from the second time in the reading screen: on the Background button. Recording is free.
struct BackgroundModesTip: Tip {
    var title: Text { Text("Camera, Audio or Color") }
    var message: Text? { Text("Film yourself with the script under the lens, record just your voice, or read on a plain color.") }
    var image: Image? { Image(systemName: "camera.fill") }
    var rules: [Rule] {
        #Rule(TipState.playerOpened) { $0.donations.count >= 2 }
    }
}

/// Everyone, from the third time in the reading screen: on the text display button.
struct TextDisplayTip: Tip {
    var title: Text { Text("Make It Easy to Read") }
    var message: Text? { Text("Change the text size, font and spacing to suit your eyes and how far you sit.") }
    var image: Image? { Image(systemName: "textformat.size") }
    var rules: [Rule] {
        #Rule(TipState.playerOpened) { $0.donations.count >= 3 }
    }
}

/// Pro, from the fourth time in the reading screen.
struct PictureInPictureTip: Tip {
    var title: Text { Text("Read Over Any App") }
    var message: Text? { Text("Keep your script over the Camera app or a video call.") }
    var image: Image? { Image(systemName: "pip.enter") }
    var rules: [Rule] {
        #Rule(TipState.$isPro) { $0 == true }
        #Rule(TipState.playerOpened) { $0.donations.count >= 4 }
    }
}

// MARK: - Recording editor

/// The first time in the editor.
struct CaptionsTip: Tip {
    var title: Text { Text("Add Captions in One Tap") }
    var message: Text? { Text("Lyrics or Clean: captions are spelled exactly like your script.") }
    var image: Image? { Image(systemName: "captions.bubble.fill") }
}

/// Pro, from the second time in the editor.
struct RemovePausesTip: Tip {
    var title: Text { Text("Tighten Your Take") }
    var message: Text? { Text("Remove Pauses cuts the silences between your sentences.") }
    var image: Image? { Image(systemName: "scissors") }
    var rules: [Rule] {
        #Rule(TipState.$isPro) { $0 == true }
        #Rule(TipState.editorOpened) { $0.donations.count >= 2 }
    }
}

/// Free, from the second time in the editor.
struct SaveWithoutMarkTip: Tip {
    var title: Text { Text("Save Without the Mark") }
    var message: Text? { Text("Pro saves your videos without the yPrompt mark. You can try it free.") }
    var image: Image? { Image(systemName: "sparkles") }
    var rules: [Rule] {
        #Rule(TipState.$isPro) { $0 == false }
        #Rule(TipState.editorOpened) { $0.donations.count >= 2 }
    }
}

// MARK: - Mac

/// On Present in the Mac editor, the first time.
struct PresentTip: Tip {
    var title: Text { Text("Read Right Under Your Camera") }
    var message: Text? {
        TipState.isPro
            ? Text("Present opens your script in the notch, next to the camera. Pick the notch or a floating window in Settings.")
            : Text("Present opens your script in a floating window just below your camera, so you look into the lens.")
    }
    var image: Image? { Image(systemName: "play.fill") }
}
