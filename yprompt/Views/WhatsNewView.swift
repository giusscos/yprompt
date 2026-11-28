//
//  WhatsNewView.swift
//  yprompt
//

import SwiftUI

enum WhatsNew {
    static let seenKey = "whatsNew.seen"
    /// Change this only when the rows below change, so a bug-fix update doesn't show them again.
    static let release = "1.0.10"
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
        row("film.stack", .orange, "Add Clips to Your Recordings",
            "Put in footage from Photos or Files, and move through your recording on a timeline you can swipe and pinch.")
        row("textformat", .pink, "Make the Captions Yours",
            "Pick a font, colors and a background, or box just the word being said.")
        row("chart.bar.xaxis", .mint, "See How You Spoke",
            "Your pace, filler words, pauses and skipped lines after every take.", isPro: true)
        #if os(iOS)
        row("square.and.pencil", .blue, "A Roomier Script Editor",
            "Your title at the top of the page, more space around every line, and formatting right above the keyboard.")
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
