//
//  RatingService.swift
//  yprompt
//

import Foundation

final class RatingService {
    static let shared = RatingService()

    private let sessionCountKey = "yprompt.completedSessions"
    private let lastRequestDateKey = "yprompt.lastReviewRequest"
    private let firstReadPaywallKey = "yprompt.firstReadPaywallShown"
    private let minimumSessions = 1
    private let minimumDaysBetweenRequests = 60

    private init() {}

    var completedSessions: Int {
        get { UserDefaults.standard.integer(forKey: sessionCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: sessionCountKey) }
    }

    // True when the user has completed enough sessions and hasn't been asked recently.
    var shouldRequestReview: Bool {
        guard completedSessions >= minimumSessions else { return false }
        guard let lastDate = UserDefaults.standard.object(forKey: lastRequestDateKey) as? Date else { return true }
        let days = Calendar.current.dateComponents([.day], from: lastDate, to: .now).day ?? 0
        return days >= minimumDaysBetweenRequests
    }

    func recordSessionCompleted() {
        completedSessions += 1
    }

    /// True once per install, after the first finished read: the moment Pro makes most sense.
    func claimFirstReadPaywall() -> Bool {
        guard !UserDefaults.standard.bool(forKey: firstReadPaywallKey) else { return false }
        UserDefaults.standard.set(true, forKey: firstReadPaywallKey)
        return true
    }

    func markReviewRequested() {
        UserDefaults.standard.set(Date.now, forKey: lastRequestDateKey)
    }
}
