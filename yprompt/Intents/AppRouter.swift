//
//  AppRouter.swift
//  yprompt
//

import Foundation
import Observation

/// Requests from App Intents (Shortcuts, Siri, Spotlight) for the app's windows to act on:
/// open a script in the editor, or start reading it. The windows watch this and clear a
/// request once they've handled it.
@Observable @MainActor
final class AppRouter {
    static let shared = AppRouter()

    enum Destination: Equatable {
        case editor(scriptID: UUID)
        case teleprompter(scriptID: UUID)
    }

    var pending: Destination?
    /// Set by a `yprompt://write` link (the In-App Event opens it): show Write Script.
    var wantsWriteScript = false

    /// `yprompt://write` opens Write Script; any other yprompt:// link just opens the app.
    func handle(_ url: URL) {
        guard url.scheme == "yprompt" else { return }
        if url.host() == "write" { wantsWriteScript = true }
    }

    func open(_ destination: Destination) {
        pending = destination
    }

    /// Hands over the pending request, once.
    func take() -> Destination? {
        defer { pending = nil }
        return pending
    }
}
