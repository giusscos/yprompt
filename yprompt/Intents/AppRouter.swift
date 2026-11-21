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

    func open(_ destination: Destination) {
        pending = destination
    }

    /// Hands over the pending request, once.
    func take() -> Destination? {
        defer { pending = nil }
        return pending
    }
}
