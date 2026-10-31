//
//  WhatsNewView.swift
//  yprompt
//

import SwiftUI

enum WhatsNew {
    static let seenKey = "whatsNew.seen"
    /// Change this only when the rows below change, so a bug-fix update doesn't show them again.
    static let release = "1.0.4"
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

                    row("mic.fill", .purple, "Voice Scroll", "Follows your words as you speak and waits when you pause.", isPro: true)
                    row("music.note.list", .green, "Lyrics Style", "Every word lights up as you read, like song lyrics.", isPro: true)
                    #if !os(macOS)
                    row("video.fill", .red, "Under the Camera", "Your script sits right under the camera, so you look straight into the lens.", isPro: true)
                    row("rectangle.and.hand.point.up.left.fill", .blue, "A Cleaner Reading Screen", "The controls step aside while you read. Tap the script to bring them back.")
                    #endif
                    row("checkmark.circle.fill", .orange, "Remembers Your Choices", "Mode, speed and text size carry over to every script, so there's nothing to set up again.")
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
