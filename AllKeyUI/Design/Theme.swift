import SwiftUI

enum ThemeAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearanceMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum Theme {
    static let accent = Color(nsColor: .systemBlue)
    static let brand = Color(red: 0.91, green: 0.69, blue: 0.23)
    static let positive = Color(nsColor: .systemGreen)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let raisedPanel = Color(nsColor: .textBackgroundColor)
    static let hairline = Color.primary.opacity(0.10)
    static let pageMaxWidth: CGFloat = 1120
}

struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            }
    }
}

extension View {
    func panel() -> some View {
        modifier(PanelModifier())
    }

    func pageContent() -> some View {
        frame(maxWidth: Theme.pageMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 20)
    }
}

struct FeatureHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 21, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .frame(maxWidth: Theme.pageMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct FieldLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

struct KeyspaceNavigationButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.accent.opacity(isEnabled && isHovered ? 0.10 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isEnabled && isHovered ? Theme.accent.opacity(0.60) : .clear, lineWidth: 1)
                }
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .help(title)
    }
}


/// Shared feedback for custom button labels while retaining Button's native action,
/// keyboard activation and focus behavior.
private struct InteractiveButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let padding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        InteractiveButtonLabel(configuration: configuration, cornerRadius: cornerRadius, padding: padding)
    }
}

private struct InteractiveButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    let padding: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0 }
        return configuration.isPressed ? 0.22 : (isHovered ? 0.10 : 0)
    }

    var body: some View {
        configuration.label
            .padding(padding)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .background(Theme.accent.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isEnabled && (isHovered || configuration.isPressed) ? Theme.accent.opacity(0.55) : .clear,
                            lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct InteractiveButtonModifier: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .buttonStyle(InteractiveButtonStyle(cornerRadius: cornerRadius, padding: padding))
            .focused($isFocused)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 2)
                    .stroke(isEnabled && isFocused ? Theme.accent : .clear, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func interactiveButton(cornerRadius: CGFloat = 7, padding: CGFloat = 0) -> some View {
        modifier(InteractiveButtonModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

struct ParameterPicker<Selection: Hashable, Content: View>: View {
    let title: String
    var width: CGFloat = 160
    @Binding var selection: Selection
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(title: title)
            Picker(title, selection: $selection) { content }
                .labelsHidden()
                .frame(width: width, alignment: .leading)
                .controlSize(.regular)
        }
    }
}

/// Keep each label and picker together; move a whole option to the next row only when needed.
struct ParameterFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 16
    var verticalSpacing: CGFloat = 10

    private func arrangement(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], sizes: [CGSize], height: CGFloat, usedWidth: CGFloat) {
        var points: [CGPoint] = [], sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(.init(width: min(ideal.width, width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            sizes.append(size)
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return (points, sizes, y + rowHeight, usedWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(width: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews)
        return CGSize(width: proposal.width ?? result.usedWidth, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            let point = result.points[index]
            let size = result.sizes[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  anchor: .topLeading, proposal: .init(width: size.width, height: size.height))
        }
    }
}


struct CoinToggle: View {
    let coin: Coin
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(coin.rawValue, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                .background(isSelected ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(isSelected ? Theme.accent.opacity(0.35) : Theme.hairline) }
        }
        .interactiveButton()
        .help(coin.name)
        .accessibilityLabel("\(coin.name)，\(isSelected ? "已选择" : "未选择")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Keep short toolbars on one row; preserve readable labels on smaller windows.
struct ResponsiveToolbar<Leading: View, Actions: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let actions: Actions

    private var buttons: some View {
        ParameterFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) { actions }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                leading.fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 8)
                buttons.fixedSize(horizontal: true, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) { leading; buttons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CoinSelectionWarning: View {
    var body: some View {
        Label("请至少选择一个币种后再生成地址。", systemImage: "exclamationmark.circle")
            .font(.caption).foregroundStyle(.orange)
    }
}
