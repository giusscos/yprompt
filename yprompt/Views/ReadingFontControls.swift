//
//  ReadingFontControls.swift
//  yprompt
//

import SwiftUI

/// Picks the reading font and letter spacing. Each choice is drawn the way it will read,
/// so it can be judged at a glance. Used on the reading screen and in Settings.
struct ReadingFontControls: View {
    /// Settings shows a title over each row; the reading screen shows a caption under both.
    var showsTitles = false

    @AppStorage(ReadingFont.key) private var readingFont: ReadingFont = .system
    @AppStorage(LetterSpacing.key) private var letterSpacing: LetterSpacing = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: showsTitles ? 14 : 10) {
            row(title: "Reading Font") {
                tiles(ReadingFont.allCases, selection: $readingFont, name: \.name) { font in
                    Text(verbatim: "Aa")
                        .font(font.font(size: 20, weight: .semibold))
                }
            }
            row(title: "Letter Spacing") {
                tiles(LetterSpacing.allCases, selection: $letterSpacing, name: \.name) { spacing in
                    Text(verbatim: "abc")
                        .font(readingFont.font(size: 16, weight: .semibold))
                        .tracking(spacing.tracking(for: 16))
                }
            }
            if !showsTitles {
                (readingFont.name + Text(verbatim: " · ") + letterSpacing.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func row<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        if showsTitles {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline)
                content()
            }
            .accessibilityElement(children: .contain)
        } else {
            content()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(title))
        }
    }

    private func tiles<Option: Identifiable & Equatable, Sample: View>(
        _ options: [Option],
        selection: Binding<Option>,
        name: @escaping (Option) -> Text,
        @ViewBuilder sample: @escaping (Option) -> Sample
    ) -> some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                let isSelected = selection.wrappedValue == option
                Button {
                    selection.wrappedValue = option
                } label: {
                    sample(option)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            Color.primary.opacity(isSelected ? 0.16 : 0.05),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.primary.opacity(0.5), lineWidth: 1.5)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

#Preview {
    ReadingFontControls(showsTitles: true).padding()
}
