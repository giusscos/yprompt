//
//  TrialReminder.swift
//  yprompt
//

import Foundation
import UserNotifications

/// A local notification shortly before the free trial ends, as the paywall promises.
/// People who trust they'll be warned have less reason to cancel the moment they start.
enum TrialReminder {
    private static let identifier = "yprompt.trialReminder"

    /// The trial day the reminder arrives on, counted from 1: two days before the end of a
    /// trial of five days or more, one day before a shorter one.
    static func reminderDay(forTrialDays days: Int) -> Int {
        max(1, days >= 5 ? days - 2 : days - 1)
    }

    /// Asks for notification permission (once) and schedules the reminder.
    static func schedule(trialEndsAt end: Date?) async {
        guard let end else { return }
        let remaining = end.timeIntervalSinceNow
        let lead: TimeInterval = remaining >= 4.5 * 86_400 ? 2 * 86_400 : 86_400
        let fireIn = remaining - lead
        guard fireIn > 60 else { return }

        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your Pro trial ends soon")
        let date = end.formatted(date: .abbreviated, time: .shortened)
        content.body = String(localized: "Your free trial ends on \(date). Keep Pro, or cancel anytime in your Apple account settings.")
        content.sound = .default

        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
