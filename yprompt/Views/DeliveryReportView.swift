//
//  DeliveryReportView.swift
//  yprompt
//

#if os(iOS) || os(macOS)
import Charts
import SwiftUI

/// How the recording was spoken: pace, filler words, long pauses and the script's skipped
/// lines. Every moment listed plays from just before it, with the video still in view.
struct DeliveryReportView: View {
    @Bindable var model: RecordingEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var previousPace: Double?

    /// Lists stop here and say how many more there are.
    private let listLimit = 8

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Delivery")
                    .font(.headline)
                Spacer()
                #if os(iOS)
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if let report = model.deliveryReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        paceCard(report)
                        fillersCard(report)
                        pausesCard(report)
                        if let coverage = report.scriptCoverage {
                            scriptCard(report, coverage: coverage)
                        }
                        Text("Counted from the words speech recognition heard, so a few may be missing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            } else {
                ContentUnavailableView("No Words Yet", systemImage: "waveform",
                                       description: Text("The report appears once your words have been heard."))
            }
        }
        .task { previousPace = model.previousPace() }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(width: 380, height: 620)
        #else
        .frame(minWidth: 320, idealWidth: 400, minHeight: 440, idealHeight: 680)
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        // Solid, so the timeline's colors don't show through the numbers.
        .presentationBackground(Color(white: 0.09))
        #endif
    }

    // MARK: Pace

    private func paceCard(_ report: DeliveryReport) -> some View {
        card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pace")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let pace = report.wordsPerMinute {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Int(pace.rounded()), format: .number)
                                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                            Text("words per minute")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Too little was said to tell.")
                            .font(.subheadline)
                    }
                }
                Spacer(minLength: 8)
                if let pace = report.pace {
                    paceBadge(pace)
                }
            }
            if let previousPace, report.wordsPerMinute != nil {
                Label {
                    Text("Your last recording: \(Int(previousPace.rounded())) words per minute")
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if report.paceSamples.count >= 3 {
                paceChart(report.paceSamples)
            }
            if let fastest = report.fastest, let time = model.timelineTime(of: fastest) {
                momentRow(time: time, title: Text("Fastest stretch"),
                          detail: Text("\(Int(fastest.wordsPerMinute.rounded())) words per minute"))
            }
            Text("About 120 to 170 words a minute is easy to follow on video.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The verdict with an icon, so it doesn't rest on color.
    private func paceBadge(_ pace: DeliveryReport.Pace) -> some View {
        let (title, icon, tint): (LocalizedStringKey, String, Color) = switch pace {
        case .slow: ("A Bit Slow", "tortoise.fill", .orange)
        case .good: ("Good Pace", "checkmark.circle.fill", .green)
        case .fast: ("A Bit Fast", "hare.fill", .orange)
        }
        return Label(title, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .labelStyle(TintedIconLabelStyle(tint: tint))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.18), in: Capsule())
    }

    /// Words per minute for each ten seconds or so, over the band that's easy to follow.
    /// Tapping a bar plays that stretch.
    private func paceChart(_ samples: [DeliveryReport.PaceSample]) -> some View {
        let band = DeliveryReport.comfortablePace
        let top = max(220, (samples.map(\.wordsPerMinute).max() ?? 0) + 20)
        return Chart {
            RectangleMark(yStart: .value("From", band.lowerBound), yEnd: .value("To", band.upperBound))
                .foregroundStyle(.white.opacity(0.08))
            ForEach(samples) { sample in
                BarMark(x: .value("Stretch", String(sample.id)), y: .value("Words per minute", sample.wordsPerMinute),
                        width: .ratio(0.6))
                    .foregroundStyle(Color.accentColor)
                    .cornerRadius(3)
                    .accessibilityLabel(Text(timeLabel(model.timelineTime(of: sample) ?? 0)))
                    .accessibilityValue(Text("\(Int(sample.wordsPerMinute.rounded())) words per minute"))
            }
        }
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 100, 200]) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.12))
                AxisValueLabel().foregroundStyle(.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let x = location.x - geometry[frame].origin.x
                        guard let value = proxy.value(atX: x, as: String.self) else { return }
                        if let sample = samples.first(where: { String($0.id) == value }),
                           let time = model.timelineTime(of: sample) {
                            model.play(from: time + 0.8)
                        }
                    }
            }
        }
        .frame(height: 96)
    }

    // MARK: Fillers

    private func fillersCard(_ report: DeliveryReport) -> some View {
        card {
            cardHeader("Filler Words", icon: "text.bubble", value: Text(report.fillers.count, format: .number))
            if report.fillers.isEmpty {
                Text("None heard.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // The most frequent first: "um ×3 · like ×2".
                let counts = Dictionary(grouping: report.fillers, by: \.text)
                    .map { (word: $0.key, count: $0.value.count) }
                    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
                Text(counts.map { "\($0.word) ×\($0.count)" }.joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
                momentList(report.fillers) { Text(verbatim: "“\($0.text)”") }
            }
        }
    }

    // MARK: Pauses

    private func pausesCard(_ report: DeliveryReport) -> some View {
        card {
            cardHeader("Long Pauses", icon: "pause.circle", value: Text(report.pauses.count, format: .number))
            if report.pauses.isEmpty {
                Text("No pauses longer than a second and a half.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                momentList(report.pauses) { pause in
                    Text(Measurement(value: pause.seconds, unit: UnitDuration.seconds),
                         format: .measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(1))))
                }
                Text(model.recording.removePauses
                     ? "Remove Pauses cuts these from the video."
                     : "Turn on Remove Pauses to cut these from the video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Script

    private func scriptCard(_ report: DeliveryReport, coverage: Double) -> some View {
        card {
            cardHeader("Script", icon: "text.alignleft", value: Text(coverage, format: .percent.precision(.fractionLength(0))))
            Text("Of the script said, from the first line you read to the last.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if report.addedWords > 0 {
                Text("Words of your own: \(report.addedWords)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if report.skipped.isEmpty {
                Label("Nothing skipped.", systemImage: "checkmark")
                    .font(.subheadline)
            } else {
                Text("Skipped")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
                momentList(report.skipped) { Text(verbatim: $0.text) }
            }
        }
    }

    // MARK: Pieces

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private func cardHeader(_ title: LocalizedStringKey, icon: String, value: Text) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            value
                .font(.title2.weight(.bold).monospacedDigit())
        }
    }

    /// The first few moments, each playing from just before it, and how many more there are.
    @ViewBuilder
    private func momentList(_ moments: [DeliveryReport.Moment],
                            title: @escaping (DeliveryReport.Moment) -> Text) -> some View {
        VStack(spacing: 2) {
            ForEach(moments.prefix(listLimit)) { moment in
                if let time = model.timelineTime(of: moment) {
                    momentRow(time: time, title: title(moment), detail: nil)
                }
            }
        }
        if moments.count > listLimit {
            Text("And \(moments.count - listLimit) more")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func momentRow(time: Double, title: Text, detail: Text?) -> some View {
        Button { model.play(from: time) } label: {
            HStack(spacing: 12) {
                Text(timeLabel(time))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    title
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        detail
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays this moment")
    }

    private func timeLabel(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

/// An icon in its own color beside text in the regular one.
private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
#endif
