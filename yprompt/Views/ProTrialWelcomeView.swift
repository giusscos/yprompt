//
//  ProTrialWelcomeView.swift
//  yprompt
//

import SwiftUI

/// Shown in place of the paywall right after a free trial starts, so the first thing
/// people do with Pro is try the tools that make it worth keeping.
struct ProTrialWelcomeView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                Text("Your Pro Trial Has Started")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Try these first to see what Pro can do.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 14) {
                row("mic.fill", .purple, "Voice Scroll", "Follows your words as you speak and waits when you pause.")
                row("music.note.list", .green, "Lyrics Style", "Every word lights up as you read, like song lyrics.")
                #if os(macOS)
                row("camera.fill", .indigo, "Mac Notch Teleprompter", "Read from the notch, right next to your Mac's camera.")
                #else
                row("pip.fill", .indigo, "Picture in Picture", "Keep your script over the Camera app or a video call.")
                #endif
                row("sparkles.rectangle.stack.fill", .orange, "No yPrompt Mark", "Save your videos without the \"Made with yPrompt\" mark.")
            }
            .padding(16)
            .ypGlassEffect(cornerRadius: 16)

            Text("Cancel anytime in your Apple account settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onDone) {
                Text("Start Using Pro")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .ypGlassProminentButtonStyle()
            .buttonBorderShape(.capsule)
            .tint(Color.accentColor)
        }
    }

    private func row(_ icon: String, _ color: Color, _ title: LocalizedStringKey, _ description: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
