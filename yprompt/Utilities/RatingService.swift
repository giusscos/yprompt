//
//  RatingService.swift
//  yprompt
//

import Foundation
import StoreKit
import TipKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Decides when to ask for an App Store rating, and asks.
///
/// Apple shows the system rating sheet at most three times a year per person and decides
/// on its own whether a request shows at all, so a request that doesn't appear costs nothing.
/// The rules below keep requests to happy moments, after someone has come back on a second
/// day, and never twice for the same version.
final class RatingService {
    static let shared = RatingService()

    private let defaults = UserDefaults.standard

    // Kept from earlier versions so existing installs keep their history.
    private let sessionCountKey = "yprompt.completedSessions"
    private let lastRequestDateKey = "yprompt.lastReviewRequest"
    private let firstReadPaywallKey = "yprompt.firstReadPaywallShown"
    private let savedRecordingsKey = "yprompt.savedRecordings"

    private let momentsKey = "yprompt.review.moments"
    private let activeDaysKey = "yprompt.review.activeDays"
    private let lastActiveDayKey = "yprompt.review.lastActiveDay"
    private let requestDatesKey = "yprompt.review.requestDates"
    private let lastRequestedVersionKey = "yprompt.review.lastVersion"

    /// Good moments (a finished read, a saved recording, a draft added) before the first request.
    private let minimumMoments = 2
    /// Separate days the app was opened on. Someone who comes back is someone who likes it.
    private let minimumActiveDays = 2
    private let minimumDaysBetweenRequests = 14
    private let maximumRequestsPerYear = 3

    private init() {}

    // MARK: - What happened

    var completedSessions: Int {
        get { defaults.integer(forKey: sessionCountKey) }
        set { defaults.set(newValue, forKey: sessionCountKey) }
    }

    var savedRecordings: Int {
        get { defaults.integer(forKey: savedRecordingsKey) }
        set { defaults.set(newValue, forKey: savedRecordingsKey) }
    }

    private var moments: Int {
        get { defaults.integer(forKey: momentsKey) }
        set { defaults.set(newValue, forKey: momentsKey) }
    }

    private var activeDays: Int {
        get { defaults.integer(forKey: activeDaysKey) }
        set { defaults.set(newValue, forKey: activeDaysKey) }
    }

    func recordSessionCompleted() {
        completedSessions += 1
        moments += 1
        Task { await TipState.readFinished.donate() }
    }

    func recordRecordingSaved() {
        savedRecordings += 1
        moments += 1
    }

    /// A Write Script draft was added, or anything else that means "this worked".
    func recordPositiveMoment() {
        moments += 1
    }

    /// Call when the app becomes active. Counts each calendar day once.
    func recordAppActive() {
        let today = Self.dayString(.now)
        guard defaults.string(forKey: lastActiveDayKey) != today else { return }
        defaults.set(today, forKey: lastActiveDayKey)
        activeDays += 1
        // Installs from before this counter existed already have reads or recordings behind them.
        if activeDays == 1, completedSessions + savedRecordings > 0 { activeDays = 2 }
        if moments == 0 { moments = completedSessions + savedRecordings }
    }

    // MARK: - Asking

    /// True after enough good moments on at least two days, if this version hasn't asked yet.
    var shouldRequestReview: Bool {
        guard moments >= minimumMoments, activeDays >= minimumActiveDays else { return false }
        return requestAllowedNow
    }

    private var requestAllowedNow: Bool {
        guard defaults.string(forKey: lastRequestedVersionKey) != Self.appVersion else { return false }
        let yearAgo = Date.now.addingTimeInterval(-365 * 24 * 3600)
        let recent = requestDates.filter { $0 > yearAgo }
        guard recent.count < maximumRequestsPerYear else { return false }
        if let last = recent.max() ?? defaults.object(forKey: lastRequestDateKey) as? Date {
            let days = Calendar.current.dateComponents([.day], from: last, to: .now).day ?? 0
            guard days >= minimumDaysBetweenRequests else { return false }
        }
        return true
    }

    private var requestDates: [Date] {
        (defaults.array(forKey: requestDatesKey) as? [Date]) ?? []
    }

    func markReviewRequested() {
        defaults.set(Date.now, forKey: lastRequestDateKey)
        defaults.set(Self.appVersion, forKey: lastRequestedVersionKey)
        let yearAgo = Date.now.addingTimeInterval(-365 * 24 * 3600)
        defaults.set(requestDates.filter { $0 > yearAgo } + [Date.now], forKey: requestDatesKey)
    }

    /// Records a good moment and, if the rules allow, asks for a rating after `delay`,
    /// so the sheet doesn't land on top of what just happened.
    @MainActor
    func momentHappened(askAfter delay: Duration = .seconds(1.5), countsAsMoment: Bool = true) {
        if countsAsMoment { recordPositiveMoment() }
        requestIfAppropriate(after: delay)
    }

    @MainActor
    func requestIfAppropriate(after delay: Duration = .seconds(1.5)) {
        guard shouldRequestReview else { return }
        markReviewRequested()
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            Self.presentSystemPrompt()
        }
    }

    /// Someone who just bought Pro is as happy as they will ever be with the app.
    @MainActor
    func purchaseCompleted() {
        recordPositiveMoment()
        guard activeDays >= 1, requestAllowedNow else { return }
        markReviewRequested()
        Task { @MainActor in
            // After the paywall has closed.
            try? await Task.sleep(for: .seconds(2.5))
            Self.presentSystemPrompt()
        }
    }

    @MainActor
    private static func presentSystemPrompt() {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            AppStore.requestReview(in: scene)
        }
        #elseif os(macOS)
        SKStoreReviewController.requestReview()
        #endif
    }

    /// The App Store's "Write a Review" page. Always opens, unlike the system sheet,
    /// so it's what the Rate button in Settings uses.
    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6777453211?action=write-review")!

    // MARK: - Paywall

    /// True once per install, after the first finished read: the moment Pro makes most sense.
    func claimFirstReadPaywall() -> Bool {
        guard !defaults.bool(forKey: firstReadPaywallKey) else { return false }
        defaults.set(true, forKey: firstReadPaywallKey)
        return true
    }

    // MARK: - Helpers

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
