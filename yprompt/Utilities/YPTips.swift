//
//  YPTips.swift
//  yprompt
//

import SwiftUI
import TipKit

/// What the tips know about the reader.
///
/// Each screen shows at most one tip per visit, and only one that fits the moment: a tip about
/// Remove Pauses when the take has long pauses, about Voice once the speed has been fiddled
/// with, and so on. Which one is up is worked out here from a few counts, kept in
/// UserDefaults so it's known straight away; TipKit only presents the tip and remembers it
/// was closed (or acted on).
enum TipState {
    /// Pro or a Pro trial. Kept up to date by `ContentView`.
    @Parameter static var isPro: Bool = false

    static let scriptCreated = Tips.Event(id: "yp.scriptCreated")

    // MARK: Counts

    private static let defaults = UserDefaults.standard
    private static func count(_ key: String) -> Int { defaults.integer(forKey: "tips." + key) }
    private static func bump(_ key: String) { defaults.set(count(key) + 1, forKey: "tips." + key) }
    private static let keys = ["readingVisits", "speedChanges", "finishedReads", "takes", "cameraTakes",
                               "editorVisits", "markedSaves", "scriptsCreated"]

    /// Times the reading screen has opened, this one included once `readingOpened()` has run.
    static var readingVisits: Int { count("readingVisits") }
    static var speedChanges: Int { count("speedChanges") }
    static var finishedReads: Int { count("finishedReads") }
    static var takes: Int { count("takes") }
    static var cameraTakes: Int { count("cameraTakes") }
    static var editorVisits: Int { count("editorVisits") }
    /// Recordings saved with the yPrompt mark on them.
    static var markedSaves: Int { count("markedSaves") }
    static var scriptsCreated: Int { count("scriptsCreated") }

    static func readingOpened() { bump("readingVisits") }
    static func speedChanged() { bump("speedChanges") }
    static func readFinished() { bump("finishedReads") }
    static func takeRecorded(withCamera: Bool) {
        bump("takes")
        if withCamera { bump("cameraTakes") }
    }
    static func editorOpened() { bump("editorVisits") }
    static func savedWithMark() { bump("markedSaves") }
    static func createdScript() {
        bump("scriptsCreated")
        Task { await scriptCreated.donate() }
    }

    /// The first tip in `candidates` that hasn't been closed, acted on or shown enough, or nil.
    static func first<T>(of candidates: [(T, any Tip)]) async -> T? {
        for (value, tip) in candidates where await isOpen(tip) { return value }
        return nil
    }

    /// Whether a tip can still show. TipKit only works that out once something watches the
    /// tip, so this watches it for a moment.
    static func isOpen(_ tip: any Tip) async -> Bool {
        let updates = tip.statusUpdates
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                for await status in updates {
                    switch status {
                    case .available: return true
                    case .invalidated: return false
                    default: continue
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(500))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }

    static func configure() {
        #if DEBUG
        // `-ypResetTips` shows every tip again, from a first visit.
        if ProcessInfo.processInfo.arguments.contains("-ypResetTips") {
            try? Tips.resetDatastore()
            keys.forEach { defaults.removeObject(forKey: "tips." + $0) }
        }
        // App Store screenshots stay free of tips.
        if ProcessInfo.processInfo.arguments.contains("-ypDemoStore") { Tips.hideAllTipsForTesting() }
        #endif
        try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
    }
}

/// Closing a popover tip by tapping elsewhere doesn't close it for good, so it would come back
/// on every visit. After three showings it gives the next tip its turn.
let ypTipOptions: [any TipOption] = [Tips.MaxDisplayCount(3)]

extension Tip {
    /// Closes the tip for good: it was acted on.
    func done() { invalidate(reason: .actionPerformed) }
}

// MARK: - Scripts

/// On New Script (in the list before iOS 26), until the first script of one's own is made.
struct NewScriptTip: Tip {
    var title: Text { Text("Add Your First Script") }
    var message: Text? { Text("Type or paste your text, or import a file. Then press play.") }
    var image: Image? { Image(systemName: "plus.circle.fill") }
    var actions: [Action] { [Action(id: "create") { Text("Create Script") }] }
    var rules: [Rule] {
        #Rule(TipState.scriptCreated) { $0.donations.count == 0 }
    }
}

/// On Write with Apple Intelligence, once a script of one's own has been made and read.
struct WriteScriptTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Need a Script? Ask for a Draft") }
    var message: Text? { Text("Say what it's about, how long and in what tone. Apple Intelligence writes a draft on your device.") }
    var image: Image? { Image(systemName: "sparkles") }
    var actions: [Action] { [Action(id: "write") { Text("Write a Draft") }] }
}

/// On Present in the script editor, the first time.
struct PresentTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text {
        #if os(macOS)
        Text("Read Right Under Your Camera")
        #else
        Text("Read It Out Loud")
        #endif
    }
    var message: Text? {
        #if os(macOS)
        TipState.isPro
            ? Text("Present opens your script in the notch, next to the camera. Pick the notch or a floating window in Settings.")
            : Text("Present opens your script in a floating window just below your camera, so you look into the lens.")
        #else
        Text("Opens the teleprompter. Turn on the camera there to film yourself while you read.")
        #endif
    }
    var image: Image? { Image(systemName: "play.fill") }
}

// MARK: - Reading (iPhone and iPad)

/// The reading screen's tips, in the order they're offered: one per visit.
enum ReadingTip: Hashable {
    case voice, background, underCamera, display, pictureInPicture
}

/// Pro, on the first visit: Voice is what Pro is about.
struct VoiceScrollProTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Let Your Voice Lead") }
    var message: Text? { Text("With Voice, the script follows your words and waits when you pause.") }
    var image: Image? { Image(systemName: "mic.fill") }
    var actions: [Action] { [Action(id: "voice") { Text("Use Voice") }] }
}

/// Free, once the reader has had to work the speed: changed it a few times, finished a read,
/// or come back a third time.
struct VoiceScrollFreeTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Stop Chasing the Speed") }
    var message: Text? { Text("With Voice, the script follows your words and waits when you pause. It's part of Pro, and you can try it free.") }
    var image: Image? { Image(systemName: "mic.fill") }
    var actions: [Action] { [Action(id: "voice") { Text("Try Voice") }] }
}

/// From the second visit, to someone who hasn't recorded yet. Recording is free.
struct BackgroundModesTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Record While You Read") }
    var message: Text? { Text("Film yourself with the script by the lens, or record just your voice. Captions are made from your script.") }
    var image: Image? { Image(systemName: "camera.fill") }
    var actions: [Action] { [Action(id: "camera") { Text("Turn On the Camera") }] }
}

/// After a first camera take read with the text over the whole preview.
struct UnderCameraTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Keep Your Eyes Near the Lens") }
    var message: Text? { Text("Under the Camera puts a few lines right below the lens, so you look into it as you read.") }
    var image: Image? { Image(systemName: "rectangle.topthird.inset.filled") }
    var actions: [Action] { [Action(id: "underCamera") { Text("Use Under the Camera") }] }
}

/// After a finished read, or from the third visit.
struct TextDisplayTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Make It Easy to Read") }
    var message: Text? { Text("Change the text size, font and spacing to suit your eyes and how far you sit.") }
    var image: Image? { Image(systemName: "textformat.size") }
    var actions: [Action] { [Action(id: "display") { Text("Adjust the Text") }] }
}

/// Pro, from the fourth visit.
struct PictureInPictureTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Read Over Any App") }
    var message: Text? { Text("Keep your script over the Camera app or a video call.") }
    var image: Image? { Image(systemName: "pip.enter") }
    var actions: [Action] { [Action(id: "pip") { Text("Try It") }] }
}

// MARK: - Recording editor

/// The recording editor's tips, in the order they're offered: one per visit.
enum EditorTip: Hashable {
    case captions, removePauses, timeline, saveWithoutMark, delivery, captionStyle, addClip
}

/// A video with captions off.
struct CaptionsTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Add Captions in One Tap") }
    var message: Text? { Text("Lyrics or Clean: captions are spelled exactly like your script.") }
    var image: Image? { Image(systemName: "captions.bubble.fill") }
    var actions: [Action] { [Action(id: "lyrics") { Text("Add Lyrics Captions") }] }
}

/// A take with long pauses, and Remove Pauses off.
struct RemovePausesTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    /// Set before the tip is offered.
    static var pauses = 0

    var title: Text { Text("Tighten Your Take") }
    var message: Text? {
        Self.pauses == 1
            ? Text("There's a long pause in this take. Remove Pauses cuts the silences between your sentences.")
            : Text("There are \(Self.pauses) long pauses in this take. Remove Pauses cuts the silences between your sentences.")
    }
    var image: Image? { Image(systemName: "scissors") }
    var actions: [Action] { [Action(id: "remove") { Text("Remove Pauses") }] }
}

/// On the timeline: its gestures can't be seen.
struct TimelineTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Move Through Your Recording") }
    var message: Text? {
        #if os(macOS)
        Text("Scroll sideways or drag to move through it, and pinch to zoom. Hold a piece to move it.")
        #else
        Text("Swipe to move through it and pinch to zoom. Hold a piece to move it.")
        #endif
    }
    var image: Image? { Image(systemName: "hand.draw.fill") }
}

/// Free, on the next visit after saving a video with the mark.
struct SaveWithoutMarkTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Save Without the Mark") }
    var message: Text? { Text("Pro saves your videos without the yPrompt mark. You can try it free.") }
    var image: Image? { Image(systemName: "sparkles") }
    var actions: [Action] { [Action(id: "pro") { Text("Try Pro Free") }] }
}

/// On the delivery row, from the second visit.
struct DeliveryTip: Tip {
    /// Pro opens the report; otherwise the tip says it's part of Pro.
    var isPro = false

    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("See How You Spoke") }
    var message: Text? {
        isPro
            ? Text("Your pace, filler words, long pauses and skipped lines, each one a tap away.")
            : Text("Your pace, filler words, long pauses and skipped lines, each one a tap away. Part of Pro.")
    }
    var image: Image? { Image(systemName: "chart.bar.xaxis") }
    var actions: [Action] {
        [Action(id: "report") { isPro ? Text("Show the Report") : Text("Learn More") }]
    }
}

/// On the caption style button, once captions are on and still look the way they started.
struct CaptionStyleTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Make the Captions Yours") }
    var message: Text? { Text("Pick a font, colors and a background, or box just the word being said.") }
    var image: Image? { Image(systemName: "textformat") }
    var actions: [Action] { [Action(id: "style") { Text("Open Caption Style") }] }
}

/// On Add After, from the third visit.
struct AddClipTip: Tip {
    var options: [any TipOption] { ypTipOptions }
    var title: Text { Text("Add Clips") }
    var message: Text? { Text("Put in footage from Photos or Files, or record another piece, after the one you've picked.") }
    var image: Image? { Image(systemName: "plus.rectangle.on.rectangle") }
}

// MARK: - Presenting

#if os(iOS) || os(macOS) || os(visionOS)
extension View {
    /// A popover tip that may be none: this visit's tip, or nil when it's another's turn.
    /// Before iOS 18.4 and macOS 15.4 a popover tip has to be of a known type, so there the
    /// tip is opened up and the view rebuilt when it arrives.
    @ViewBuilder
    func ypPopoverTip(_ tip: (any Tip)?, arrowEdge: Edge? = nil,
                      action: @escaping @MainActor @Sendable (Tips.Action) -> Void = { _ in }) -> some View {
        if #available(iOS 18.4, macOS 15.4, visionOS 2.4, *) {
            popoverTip(tip, arrowEdge: arrowEdge, action: action)
        } else if let tip {
            legacyPopoverTip(tip, arrowEdge: arrowEdge ?? .top, action: action)
        } else {
            self
        }
    }

    private func legacyPopoverTip<T: Tip>(_ tip: T, arrowEdge: Edge,
                                          action: @escaping @MainActor @Sendable (Tips.Action) -> Void) -> AnyView {
        AnyView(popoverTip(tip, arrowEdge: arrowEdge, action: action))
    }
}
#endif

#if os(iOS)
import UIKit

/// A tip on a toolbar button, shown with UIKit's tip popover from the button's own bar item.
/// On iOS 26 a plain SwiftUI toolbar button becomes a native bar button item, and anything
/// attached to it, a `popoverTip` included, is dropped. Put this anywhere in the screen's
/// content: it finds the screen's bar item by its title (the button's label, as shown to
/// VoiceOver), since SwiftUI doesn't pass an accessibility identifier on to the item.
struct BarItemTip<T: Tip>: UIViewRepresentable {
    let tip: T
    let itemTitle: String
    /// False keeps it from showing, as while onboarding covers the screen.
    var isEnabled = true
    var action: @MainActor @Sendable (Tips.Action) -> Void = { _ in }

    func makeUIView(context: Context) -> BarItemTipView<T> {
        let view = BarItemTipView(tip: tip, itemTitle: itemTitle)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: BarItemTipView<T>, context: Context) {
        view.action = action
        view.isEnabled = isEnabled
    }
}

final class BarItemTipView<T: Tip>: UIView {
    private let tip: T
    private let itemTitle: String
    var action: @MainActor @Sendable (Tips.Action) -> Void = { _ in }
    var isEnabled = true {
        didSet { if isEnabled != oldValue { watch() } }
    }
    private var watching: Task<Void, Never>?
    private weak var popover: UIViewController?

    init(tip: T, itemTitle: String) {
        self.tip = tip
        self.itemTitle = itemTitle
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { dismissPopover() }
        watch()
    }

    /// Shows the tip while TipKit says it should, from when this is on screen.
    private func watch() {
        watching?.cancel()
        guard window != nil, isEnabled else {
            watching = nil
            return
        }
        let tip = tip
        watching = Task { [weak self] in
            // Once the screen has settled: a popover asked for mid-transition doesn't show.
            try? await Task.sleep(for: .milliseconds(700))
            for await shouldDisplay in tip.shouldDisplayUpdates {
                guard let self, !Task.isCancelled else { return }
                if shouldDisplay { self.present() } else { self.dismissPopover() }
            }
        }
    }

    private func present() {
        guard popover?.presentingViewController == nil, window != nil,
              let host = hostController, host.presentedViewController == nil,
              let item = barItem(in: host) else { return }
        let action = action
        let controller = TipUIPopoverViewController(tip, sourceItem: item) { tipAction in action(tipAction) }
        popover = controller
        host.present(controller, animated: true)
    }

    private func dismissPopover() {
        if let popover, popover.presentingViewController != nil { popover.dismiss(animated: true) }
        popover = nil
    }

    /// The nearest view controller up the chain.
    private var hostController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// The bar item titled `itemTitle`, among the items of the screen this is on.
    private func barItem(in host: UIViewController) -> UIBarButtonItem? {
        var controller: UIViewController? = host
        while let current = controller {
            let item = current.navigationItem
            let items = (item.rightBarButtonItems ?? []) + (item.leftBarButtonItems ?? [])
                + item.trailingItemGroups.flatMap(\.barButtonItems)
                + item.leadingItemGroups.flatMap(\.barButtonItems)
            if let match = items.first(where: { $0.title == itemTitle }) { return match }
            controller = current.parent
        }
        return nil
    }
}
#endif
