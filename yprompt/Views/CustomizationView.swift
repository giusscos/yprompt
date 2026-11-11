//
//  CustomizationView.swift
//  yprompt
//

import SwiftUI
import SwiftData

struct CustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(StoreKitService.self) private var storeKit
    @Bindable var script: Script

    @State private var customization: TextCustomization
    @State private var showingPaywall = false
    @AppStorage(ReadingFont.key) private var readingFont: ReadingFont = .system
    @AppStorage(LetterSpacing.key) private var letterSpacing: LetterSpacing = .normal

    init(script: Script) {
        self.script = script
        var current = script.customization
        if ReadingPreferences.fontSize > 0 { current.fontSize = ReadingPreferences.fontSize }
        if ReadingPreferences.speed > 0 { current.scrollSpeed = ReadingPreferences.speed }
        self._customization = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            #if os(macOS)
            macOSLayout
            #else
            iOSLayout
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 600)
        #endif
        .sheet(isPresented: $showingPaywall) {
            PaywallView().environment(storeKit)
        }
    }

    // MARK: - iOS Layout
    #if !os(macOS)
    private var iOSLayout: some View {
        Form {
            colorsSection
            layoutSection
            teleprompterSection
            previewSection
        }
        .navigationTitle("Customize")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") { applyAndDismiss() }.fontWeight(.bold)
            }
        }
    }
    #endif

    // MARK: - macOS Layout

    #if os(macOS)
    private var macOSLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                previewCard
                    .padding(.horizontal)
                    .padding(.top, 8)

                macOSSection("Colors") { colorControls }
                macOSSection("Layout") { layoutControls }
                macOSSection("Teleprompter") { teleprompterControls }
            }
            .padding(.bottom, 20)
        }
        .navigationTitle("Customize")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") { applyAndDismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func macOSSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 10) {
                content()
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }
    #endif

    // MARK: - Preview Card (shared)

    private var previewCard: some View {
        ZStack {
            Color(hex: customization.backgroundColorHex)
                .opacity(customization.transparency)
            let sample = String(localized: "The quick brown fox jumps over the lazy dog.")
            Text(sample)
                .font(readingFont.resolved(for: sample).font(size: min(customization.fontSize, 24)))
                .tracking(letterSpacing.tracking(for: min(customization.fontSize, 24), in: sample))
                .foregroundStyle(Color(hex: customization.textColorHex))
                .multilineTextAlignment(customization.textAlignmentIndex.textAlignment)
                .lineSpacing((customization.lineHeight - 1.0) * 14)
                .padding()
                .scaleEffect(x: customization.isMirrored ? -1 : 1, y: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
    }

    // MARK: - iOS Form Sections

    private var colorsSection: some View {
        Section("Colors") {
            colorPickerRow("Text Color", presets: AppConstants.textColorPresets,
                           selected: $customization.textColorHex)
            colorPickerRow("Background", presets: AppConstants.backgroundColorPresets,
                           selected: $customization.backgroundColorHex)
        }
    }

    private var layoutSection: some View {
        Section("Layout") {
            sliderRow("Font Size", value: $customization.fontSize,
                      range: AppConstants.minFontSize...AppConstants.maxFontSize, step: 1,
                      display: "\(Int(customization.fontSize))pt")
            sliderRow("Line Height", value: $customization.lineHeight,
                      range: AppConstants.minLineHeight...AppConstants.maxLineHeight, step: 0.1,
                      display: String(format: "%.1f", customization.lineHeight))
            Picker("Alignment", selection: $customization.textAlignmentIndex) {
                Label("Left", systemImage: "text.alignleft").tag(0)
                Label("Center", systemImage: "text.aligncenter").tag(1)
                Label("Right", systemImage: "text.alignright").tag(2)
            }
            .pickerStyle(.segmented)
            Toggle("Mirror Text", isOn: $customization.isMirrored)
        }
    }

    private var teleprompterSection: some View {
        Section("Teleprompter") {
            sliderRow("Scroll Speed", value: $customization.scrollSpeed,
                      range: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed, step: 0.1,
                      display: String(format: "%.1fx", customization.scrollSpeed))
            sliderRow("Transparency", value: $customization.transparency,
                      range: 0.1...1.0, step: 0.05,
                      display: "\(Int(customization.transparency * 100))%")
            Toggle("Auto Scroll", isOn: $customization.isAutoScroll)
        }
    }

    private var previewSection: some View {
        Section("Preview") { previewCard }
    }

    // MARK: - macOS Inline Controls

    #if os(macOS)
    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            colorPickerRow("Text Color", presets: AppConstants.textColorPresets,
                           selected: $customization.textColorHex)
            Divider()
            colorPickerRow("Background", presets: AppConstants.backgroundColorPresets,
                           selected: $customization.backgroundColorHex)
        }
    }

    private var layoutControls: some View {
        VStack(spacing: 10) {
            macSliderRow("Font Size", value: $customization.fontSize,
                         range: AppConstants.minFontSize...AppConstants.maxFontSize, step: 1,
                         display: "\(Int(customization.fontSize))pt")
            macSliderRow("Line Height", value: $customization.lineHeight,
                         range: AppConstants.minLineHeight...AppConstants.maxLineHeight, step: 0.1,
                         display: String(format: "%.1f", customization.lineHeight))
            HStack {
                Text("Alignment").frame(width: 100, alignment: .leading)
                Picker("", selection: $customization.textAlignmentIndex) {
                    Label("Left", systemImage: "text.alignleft").tag(0)
                    Label("Center", systemImage: "text.aligncenter").tag(1)
                    Label("Right", systemImage: "text.alignright").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Text("Mirror").frame(width: 100, alignment: .leading)
                Toggle("", isOn: $customization.isMirrored).labelsHidden()
                Spacer()
            }
        }
    }

    private var teleprompterControls: some View {
        VStack(spacing: 10) {
            macSliderRow("Scroll Speed", value: $customization.scrollSpeed,
                         range: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed, step: 0.1,
                         display: String(format: "%.1fx", customization.scrollSpeed))
            macSliderRow("Transparency", value: $customization.transparency,
                         range: 0.1...1.0, step: 0.05,
                         display: "\(Int(customization.transparency * 100))%")
            HStack {
                Text("Auto Scroll").frame(width: 100, alignment: .leading)
                Toggle("", isOn: $customization.isAutoScroll).labelsHidden()
                Spacer()
            }
        }
    }

    private func macSliderRow(_ label: String, value: Binding<CGFloat>,
                               range: ClosedRange<CGFloat>, step: CGFloat, display: String) -> some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(display).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
    }

    private func macSliderRow(_ label: String, value: Binding<Double>,
                               range: ClosedRange<Double>, step: Double, display: String) -> some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(display).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
    }
    #endif

    // MARK: - Shared Helpers

    private func sliderRow(_ label: String, value: Binding<CGFloat>,
                            range: ClosedRange<CGFloat>, step: CGFloat, display: String) -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: range, step: step)
            Text(display).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                            range: ClosedRange<Double>, step: Double, display: String) -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: range, step: step)
            Text(display).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
    }

    private func colorPickerRow(
        _ label: String,
        presets: [(name: String, hex: String)],
        selected: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.bold())
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                spacing: 8
            ) {
                ForEach(Array(presets.enumerated()), id: \.element.hex) { index, preset in
                    let isLocked = !storeKit.isPremium && index >= AppConstants.freeColorPresets
                    Circle()
                        .fill(Color(hex: preset.hex))
                        .frame(width: 36, height: 36)
                        .overlay {
                            if selected.wrappedValue == preset.hex {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                            } else {
                                Circle().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if isLocked { lockBadge }
                        }
                        .onTapGesture {
                            if isLocked {
                                showingPaywall = true
                            } else {
                                selected.wrappedValue = preset.hex
                            }
                        }
                        .accessibilityLabel(Text(LocalizedStringKey(preset.name)))
                        .accessibilityAddTraits(selected.wrappedValue == preset.hex ? [.isButton, .isSelected] : .isButton)
                }
            }
            customColorRow(selected: selected)
        }
        .padding(.vertical, 2)
    }

    private var lockBadge: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(.black.opacity(0.65), in: Circle())
            .accessibilityLabel("Pro")
    }

    /// Any color is Pro; free users get the first row of presets.
    @ViewBuilder
    private func customColorRow(selected: Binding<String>) -> some View {
        if storeKit.isPremium {
            ColorPicker("Custom Color", selection: Binding(
                get: { Color(hex: selected.wrappedValue) },
                set: { selected.wrappedValue = $0.toHex() }
            ), supportsOpacity: false)
            .font(.subheadline)
        } else {
            Button { showingPaywall = true } label: {
                HStack {
                    Text("Custom Color").font(.subheadline).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Apply

    private func applyAndDismiss() {
        script.customization = customization
        try? modelContext.save()
        ReadingPreferences.fontSize = customization.fontSize
        ReadingPreferences.speed = customization.scrollSpeed
        ReadingPreferences.newScriptStyle = customization
        dismiss()
    }
}
