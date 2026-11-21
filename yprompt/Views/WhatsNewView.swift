//
//  WhatsNewView.swift
//  yprompt
//

import SwiftUI

enum WhatsNew {
    static let seenKey = "whatsNew.seen"
    /// Change this only when the rows below change, so a bug-fix update doesn't show them again.
    static let release = "1.0.8"
}

/// Shown once to people who update. New installs get the onboarding instead.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StoreKitService.self) private var storeKit

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("What's New in yPrompt")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 32)

                    rows
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            Button {
                dismiss()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .ypGlassProminentButtonStyle()
            .buttonBorderShape(.capsule)
            .tint(Color.accentColor)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .presentationBackground(.ultraThinMaterial)
    }

    @ViewBuilder
    private var rows: some View {
        #if os(macOS)
        row("record.circle", .red, "Record While You Read", "Record video or audio from the notch or the floating prompter, with a camera preview you can move and resize.")
        row("film.stack", .orange, "Edit Your Takes", "Trim, split and caption your recordings, then save them as video files or share them.")
        if ScriptWriter.isAvailable {
            row("sparkles", .purple, "Write with Apple Intelligence", "Describe your topic, pick a length and a tone, and get a first draft written on your Mac.")
        }
        row("menubar.rectangle", .blue, "A Simpler Menu Bar", "Reading, recording and display settings, laid out more clearly.")
        row("mic.fill", .green, "Siri and Shortcuts", "Start the teleprompter or a recording from Siri, Spotlight or the Shortcuts app.")
        #else
        row("pip.enter", .blue, "Picture in Picture", "Keep your script floating over the Camera app, social apps or a video call. Play, pause and skip from the window.", isPro: true)
        if ScriptWriter.isAvailable {
            row("sparkles", .purple, "Write with Apple Intelligence", "Describe your topic, pick a length and a tone, and get a first draft written on your iPhone.")
        }
        row("applewatch", .red, "Record from Apple Watch", "Start and stop a take from your wrist while the camera is ready.")
        row("mic.fill", .green, "Siri and Shortcuts", "Start the teleprompter or a recording from Siri, Spotlight or the Shortcuts app.")
        #endif
    }

    private func row(_ icon: String, _ color: Color, _ title: LocalizedStringKey, _ description: LocalizedStringKey, isPro: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if isPro && !storeKit.isPremium {
                        Text(verbatim: "PRO")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    WhatsNewView()
        .environment(StoreKitService())
}
