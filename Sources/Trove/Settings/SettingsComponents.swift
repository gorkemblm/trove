import SwiftUI

/// Building blocks of the settings window: a tab bar with icons, sections separated by thin
/// lines, and rows with a right-aligned label column. Every control lines up on one edge.

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, storage, security, privacy, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("General")
        case .storage: L("Storage")
        case .security: L("Security")
        case .privacy: L("Privacy")
        case .shortcuts: L("Shortcuts")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .storage: "internaldrive"
        case .security: "lock"
        case .privacy: "hand.raised"
        case .shortcuts: "command"
        }
    }
}

/// The tabs: plain labels; the selected one is darker with a short line under it. Neutral
/// colours only, so the window keeps the calm of the panel.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 26) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.symbol).font(.system(size: 12.5, weight: .medium))
                            Text(tab.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        }
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        Capsule().fill(selected ? Color.primary.opacity(0.85) : Color.clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64, alignment: .bottom)
        .padding(.bottom, 2)
    }
}

struct SettingsSection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
    }
}

/// A right-aligned label, then the control. Notes under the control share its left edge.
struct SettingRow<Content: View>: View {
    static var labelWidth: CGFloat { 180 }

    let label: Text
    var alignment: VerticalAlignment = .firstTextBaseline
    /// With `.top`: moves the label down to the middle of the first control.
    var labelOffset: CGFloat = 4
    let content: Content

    /// A literal label, translated.
    init(label: LocalizedStringKey, alignment: VerticalAlignment = .firstTextBaseline, labelOffset: CGFloat = 4,
         @ViewBuilder content: () -> Content) {
        self.init(text: Text(label), alignment: alignment, labelOffset: labelOffset, content: content)
    }

    /// A label that is already translated.
    init(verbatim label: String, alignment: VerticalAlignment = .firstTextBaseline, labelOffset: CGFloat = 4,
         @ViewBuilder content: () -> Content) {
        self.init(text: Text(verbatim: label), alignment: alignment, labelOffset: labelOffset, content: content)
    }

    private init(text: Text, alignment: VerticalAlignment, labelOffset: CGFloat, @ViewBuilder content: () -> Content) {
        self.label = text
        self.alignment = alignment
        self.labelOffset = labelOffset
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 20) {
            label
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
                .padding(.top, alignment == .top ? labelOffset : 0)
            VStack(alignment: .leading, spacing: 7) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingNote: View {
    let text: Text
    var color: Color = .secondary

    /// Literal notes are translated.
    init(_ key: LocalizedStringKey, color: Color = .secondary) {
        self.text = Text(key)
        self.color = color
    }

    /// Text that is already translated or is not translatable (error messages, paths).
    init(verbatim: String, color: Color = .secondary) {
        self.text = Text(verbatim: verbatim)
        self.color = color
    }

    var body: some View {
        text
            .font(.system(size: 12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460, alignment: .leading)
    }
}

/// A pop-up menu without its own label (the row has the label).
struct SettingMenu<Value: Hashable, Options: View>: View {
    @Binding var selection: Value
    @ViewBuilder let options: Options

    var body: some View {
        Picker("", selection: $selection) { options }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
    }
}

// MARK: - Appearance

/// Three tiles, each a small drawing of the panel in that appearance.
struct AppearancePicker: View {
    @Binding var selection: PanelAppearance

    var body: some View {
        HStack(spacing: 18) {
            ForEach(PanelAppearance.allCases) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 8) {
                        PanelThumbnail(appearance: option)
                            .frame(width: 128, height: 82)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                                  lineWidth: selected ? 2.5 : 1)
                            )
                        Text(option.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(selected ? Color.primary.opacity(0.08) : Color.clear, in: Capsule())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
    }
}

/// A miniature of the panel: sidebar, list and detail. System shows both halves.
struct PanelThumbnail: View {
    let appearance: PanelAppearance

    var body: some View {
        switch appearance {
        case .dark: Miniature(dark: true)
        case .light: Miniature(dark: false)
        case .system:
            Miniature(dark: false)
                .overlay(Miniature(dark: true).mask(DiagonalHalf()))
        }
    }

    private struct DiagonalHalf: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }

    private struct Miniature: View {
        let dark: Bool

        var body: some View {
            let wallpaper = dark
                ? [Color(red: 0.20, green: 0.22, blue: 0.32), Color(red: 0.10, green: 0.10, blue: 0.14)]
                : [Color(red: 0.80, green: 0.84, blue: 0.95), Color(red: 0.96, green: 0.93, blue: 0.90)]
            let panel = dark ? Color(white: 0.15) : Color(white: 0.985)
            let line = dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
            let accent = dark ? Color(red: 0.235, green: 0.361, blue: 0.659) : Color(red: 0.72, green: 0.80, blue: 0.97)

            ZStack {
                LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 0) {
                    Capsule().fill(line).frame(width: 44, height: 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                        .frame(height: 12)
                    Rectangle().fill(line).frame(height: 0.5)
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(accent).frame(width: 16, height: 4)
                            ForEach(0..<3, id: \.self) { _ in Capsule().fill(line).frame(width: 13, height: 3) }
                        }
                        .padding(5)
                        .frame(width: 24, alignment: .topLeading)
                        Rectangle().fill(line).frame(width: 0.5)
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(0..<4, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(index == 0 ? line.opacity(1.6) : line)
                                    .frame(width: index == 0 ? 30 : 24, height: 3.5)
                            }
                        }
                        .padding(5)
                        .frame(width: 40, alignment: .topLeading)
                        Rectangle().fill(line).frame(width: 0.5)
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(line).frame(height: 16)
                            ForEach(0..<2, id: \.self) { _ in Capsule().fill(line).frame(height: 2.5) }
                        }
                        .padding(5)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(width: 100, height: 58)
                .background(panel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(line, lineWidth: 0.5))
                .shadow(color: .black.opacity(dark ? 0.4 : 0.15), radius: 4, y: 2)
            }
        }
    }
}
