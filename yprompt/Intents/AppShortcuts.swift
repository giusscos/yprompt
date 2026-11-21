//
//  AppShortcuts.swift
//  yprompt
//

import AppIntents

/// Ready-made phrases for Siri and Spotlight; no setup needed.
struct YPromptShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartTeleprompterIntent(),
                    phrases: ["Start reading \(\.$script) in \(.applicationName)",
                              "Start the teleprompter in \(.applicationName)"],
                    shortTitle: "Start Teleprompter", systemImageName: "play.fill")
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Record \(\.$script) with \(.applicationName)",
                              "Record a take in \(.applicationName)"],
                    shortTitle: "Record While Reading", systemImageName: "record.circle")
        AppShortcut(intent: DraftScriptIntent(),
                    phrases: ["Write a script with \(.applicationName)"],
                    shortTitle: "Write Script", systemImageName: "sparkles")
        AppShortcut(intent: OpenScriptIntent(),
                    phrases: ["Open \(\.$target) in \(.applicationName)"],
                    shortTitle: "Open Script", systemImageName: "doc.text")
    }
}
