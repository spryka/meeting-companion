import AppKit
import SwiftUI

struct WorkspaceBrand: View {
    let narrow: Bool
    let compact: Bool

    var body: some View {
        Text(narrow ? "Meeting Companion" : "Meeting\nCompanion")
            .font(.system(size: narrow ? 16 : compact ? 13 : 14, weight: .semibold))
            .tracking(-0.3)
            .odLineBox(size: narrow ? 16 : compact ? 13 : 14, height: narrow ? 20 : compact ? 16.25 : 17.5)
            .foregroundStyle(ODColors.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

public typealias ODColors = InterfaceStyle
public typealias ODSpacing = InterfaceStyle

public enum InterfaceStyle {
    // MARK: - Spacing Scale
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 20
    public static let s6: CGFloat = 24
    public static let s8: CGFloat = 32
    public static let s10: CGFloat = 40
    public static let s12: CGFloat = 48

    // MARK: - Colors (Adaptive Light / Dark from Open Design)
    public static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x10/255.0, green: 0x13/255.0, blue: 0x19/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xe5/255.0, green: 0xe9/255.0, blue: 0xee/255.0, alpha: 1)
    })

    public static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x20/255.0, green: 0x24/255.0, blue: 0x2b/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xff/255.0, green: 0xff/255.0, blue: 0xff/255.0, alpha: 1)
    })

    public static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x19/255.0, green: 0x1e/255.0, blue: 0x25/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xf2/255.0, green: 0xf4/255.0, blue: 0xf7/255.0, alpha: 1)
    })

    public static let toolbar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x22/255.0, green: 0x27/255.0, blue: 0x2f/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xfa/255.0, green: 0xfb/255.0, blue: 0xfc/255.0, alpha: 1)
    })

    public static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0xf0/255.0, green: 0xf2/255.0, blue: 0xf6/255.0, alpha: 1)
                          : NSColor(srgbRed: 0x20/255.0, green: 0x26/255.0, blue: 0x30/255.0, alpha: 1)
    })

    public static let muted = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0xa4/255.0, green: 0xad/255.0, blue: 0xbc/255.0, alpha: 1)
                          : NSColor(srgbRed: 0x62/255.0, green: 0x6b/255.0, blue: 0x79/255.0, alpha: 1)
    })

    public static let line = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x35/255.0, green: 0x3c/255.0, blue: 0x47/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xe3/255.0, green: 0xe7/255.0, blue: 0xed/255.0, alpha: 1)
    })

    public static let hover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x30/255.0, green: 0x38/255.0, blue: 0x44/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xe6/255.0, green: 0xeb/255.0, blue: 0xf2/255.0, alpha: 1)
    })

    public static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x8a/255.0, green: 0xb9/255.0, blue: 0xff/255.0, alpha: 1)
                          : NSColor(srgbRed: 0x17/255.0, green: 0x62/255.0, blue: 0xcf/255.0, alpha: 1)
    })

    public static let accentHover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0xa6/255.0, green: 0xca/255.0, blue: 0xff/255.0, alpha: 1)
                          : NSColor(srgbRed: 0x10/255.0, green: 0x55/255.0, blue: 0xb8/255.0, alpha: 1)
    })

    public static let primaryButtonForeground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x20/255.0, green: 0x24/255.0, blue: 0x2b/255.0, alpha: 1)
                          : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    })

    public static let selected = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x23/255.0, green: 0x3c/255.0, blue: 0x5c/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xe0/255.0, green: 0xeb/255.0, blue: 0xfc/255.0, alpha: 1)
    })

    public static let selectedInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0xb0/255.0, green: 0xd0/255.0, blue: 0xff/255.0, alpha: 1)
                          : NSColor(srgbRed: 0x16/255.0, green: 0x4e/255.0, blue: 0x9e/255.0, alpha: 1)
    })

    public static let green = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x93/255.0, green: 0xd5/255.0, blue: 0xb0/255.0, alpha: 1)
                          : NSColor(srgbRed: 0x27/255.0, green: 0x70/255.0, blue: 0x4b/255.0, alpha: 1)
    })

    public static let greenBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x20/255.0, green: 0x39/255.0, blue: 0x2d/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xed/255.0, green: 0xf6/255.0, blue: 0xf0/255.0, alpha: 1)
    })

    public static let warning = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0xf0/255.0, green: 0xc4/255.0, blue: 0x78/255.0, alpha: 1)
                          : NSColor(srgbRed: 0x85/255.0, green: 0x53/255.0, blue: 0x09/255.0, alpha: 1)
    })

    public static let warningBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x3b/255.0, green: 0x31/255.0, blue: 0x20/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xff/255.0, green: 0xf6/255.0, blue: 0xe5/255.0, alpha: 1)
    })

    public static let red = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0xff/255.0, green: 0x9a/255.0, blue: 0xa8/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xb8/255.0, green: 0x2d/255.0, blue: 0x3d/255.0, alpha: 1)
    })

    public static let redBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x40/255.0, green: 0x27/255.0, blue: 0x30/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xfb/255.0, green: 0xec/255.0, blue: 0xef/255.0, alpha: 1)
    })

    public static let track = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x40/255.0, green: 0x4b/255.0, blue: 0x5b/255.0, alpha: 1)
                          : NSColor(srgbRed: 0xdc/255.0, green: 0xe2/255.0, blue: 0xeb/255.0, alpha: 1)
    })

    // MARK: - Layout Constants
    public static let sidebarWidth: CGFloat = 304
    public static let sidebarWidthCompact: CGFloat = 264
    public static let narrowBreakpoint: CGFloat = 768
    public static let wideBreakpoint: CGFloat = 1024
    public static let documentMaxWidth: CGFloat = 840
    public static let toolbarHeight: CGFloat = 72
    public static let turnAvatarSize: CGFloat = 28

    // MARK: - Color Aliases & Palettes
    public static let toolbarBackground = toolbar
    public static let text = ink
    public static let secondaryText = muted
    public static let border = line
    public static let statusGreen = green
    public static let statusAmber = warning
    public static let statusRed = red
    public static let avatarPalette: [Color] = [accent, green, warning, red]
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

struct ODButtonStyle: ButtonStyle {
    var primary = false
    var border = true
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .medium))
            .odLineBox(size: compact ? 12 : 14, height: compact ? 15.6 : 18.2)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: compact ? 32 : 36)
            .foregroundStyle(primary ? ODColors.primaryButtonForeground : ODColors.ink)
            .background(primary ? (hovered && isEnabled ? ODColors.accentHover : ODColors.accent) : (hovered && isEnabled ? ODColors.hover : ODColors.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border && !primary ? ODColors.line : .clear))
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.48)
            .onHover { hovered = $0 }
    }
}

extension View {
    func odInput() -> some View {
        font(.system(size: 15)).textFieldStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ODColors.toolbar, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ODColors.line))
    }
    // CSS line-height includes leading above the first and below the last line.
    func odLineBox(size: CGFloat, height: CGFloat) -> some View {
        let font = NSFont.systemFont(ofSize: size)
        let leading = max(0, height - (font.ascender - font.descender + font.leading))
        return lineSpacing(leading).padding(.vertical, leading / 2)
    }
}

struct ODMenuField<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let options: [(String, Selection)]
    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                Button { selection = options[index].1 } label: {
                    if selection == options[index].1 { Label(options[index].0, systemImage: "checkmark") }
                    else { Text(options[index].0) }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(options.first { $0.1 == selection }?.0 ?? "Не выбран")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 10))
            }.odInput().contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel(title)
    }
}

struct ODDialog<Content: View, Actions: View>: View {
    let title: String
    var width: CGFloat = 480
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: close) { ODIconView(.close, size: 20, color: ODColors.muted).frame(width: 36, height: 36).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Закрыть")
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 24)
            }.fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(ODColors.line).frame(height: 1)
            HStack(spacing: 8) { Spacer(minLength: 0); actions() }
                .buttonStyle(ODButtonStyle())
                .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: width)
        .foregroundStyle(ODColors.ink).background(ODColors.surface)
    }
}

struct ODField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }
}

struct ODWrappingChips: Layout {
    var trailingLast = false
    private func positions(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], sizes: [CGSize], height: CGFloat) {
        var points: [CGPoint] = [], sizes: [CGSize] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, view.sizeThatFits(.unspecified).width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + 8; rowHeight = 0 }
            points.append(CGPoint(x: trailingLast && index == subviews.count - 1 ? width - size.width : x, y: y))
            sizes.append(size)
            x += size.width + 8; rowHeight = max(rowHeight, size.height)
        }
        return (points, sizes, y + rowHeight)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 512
        return CGSize(width: width, height: positions(subviews, width: width).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(subviews, width: bounds.width)
        for (index, view) in subviews.enumerated() {
            let point = layout.points[index]
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(layout.sizes[index]))
        }
    }
}

// MARK: - Open Design Native SVG Vector Icons
public enum ODIcon: String, CaseIterable {
    case plus
    case search
    case settings
    case shield
    case record
    case play
    case pause
    case more
    case export
    case close
    case check
    case clock
    case calendar
    case people
    case back
    case edit
    case copy
    case mic
    case mute
    case stop
    case wave
    case warning
    case retry
}

public struct ODIconView: View {
    public let icon: ODIcon
    public var size: CGFloat
    public var color: Color

    public init(_ icon: ODIcon, size: CGFloat = 20, color: Color = .primary) {
        self.icon = icon
        self.size = size
        self.color = color
    }

    public init(_ icon: ODIcon, color: Color, size: CGFloat = 20) {
        self.icon = icon
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 24.0
            context.scaleBy(x: scale, y: scale)
            drawIcon(icon, in: &context)
        }
        .frame(width: size, height: size)
    }

    private func drawIcon(_ icon: ODIcon, in context: inout GraphicsContext) {
        let strokeStyle = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)

        switch icon {
        case .plus:
            var path = Path()
            path.move(to: CGPoint(x: 12, y: 5))
            path.addLine(to: CGPoint(x: 12, y: 19))
            path.move(to: CGPoint(x: 5, y: 12))
            path.addLine(to: CGPoint(x: 19, y: 12))
            context.stroke(path, with: .color(color), style: strokeStyle)

        case .search:
            var circle = Path()
            circle.addEllipse(in: CGRect(x: 4, y: 4, width: 13, height: 13))
            var line = Path()
            line.move(to: CGPoint(x: 16, y: 16))
            line.addLine(to: CGPoint(x: 20, y: 20))
            context.stroke(circle, with: .color(color), style: strokeStyle)
            context.stroke(line, with: .color(color), style: strokeStyle)

        case .settings:
            var path = Path()
            path.move(to: CGPoint(x: 9, y: 4))
            path.addLine(to: CGPoint(x: 10, y: 2))
            path.addLine(to: CGPoint(x: 14, y: 2))
            path.addLine(to: CGPoint(x: 15, y: 4))
            path.addLine(to: CGPoint(x: 17, y: 5))
            path.addLine(to: CGPoint(x: 19, y: 4.8))
            path.addLine(to: CGPoint(x: 21, y: 7.8))
            path.addLine(to: CGPoint(x: 19.8, y: 9.5))
            path.addLine(to: CGPoint(x: 19.8, y: 12.5))
            path.addLine(to: CGPoint(x: 21, y: 14))
            path.addLine(to: CGPoint(x: 19, y: 17))
            path.addLine(to: CGPoint(x: 17, y: 16.8))
            path.addLine(to: CGPoint(x: 15, y: 18))
            path.addLine(to: CGPoint(x: 14, y: 20))
            path.addLine(to: CGPoint(x: 10, y: 20))
            path.addLine(to: CGPoint(x: 9, y: 18))
            path.addLine(to: CGPoint(x: 7, y: 16.8))
            path.addLine(to: CGPoint(x: 5, y: 17))
            path.addLine(to: CGPoint(x: 3, y: 14))
            path.addLine(to: CGPoint(x: 4.2, y: 12.5))
            path.addLine(to: CGPoint(x: 4.2, y: 9.5))
            path.addLine(to: CGPoint(x: 3, y: 7.8))
            path.addLine(to: CGPoint(x: 5, y: 4.8))
            path.addLine(to: CGPoint(x: 7, y: 5))
            path.closeSubpath()
            var center = Path()
            center.addEllipse(in: CGRect(x: 9, y: 8, width: 6, height: 6))
            context.stroke(path, with: .color(color), style: strokeStyle)
            context.stroke(center, with: .color(color), style: strokeStyle)

        case .shield:
            var path = Path()
            path.move(to: CGPoint(x: 12, y: 3))
            path.addLine(to: CGPoint(x: 20, y: 6))
            path.addLine(to: CGPoint(x: 20, y: 11))
            path.addCurve(to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 20, y: 16), control2: CGPoint(x: 12, y: 21))
            path.addCurve(to: CGPoint(x: 4, y: 11), control1: CGPoint(x: 12, y: 21), control2: CGPoint(x: 4, y: 16))
            path.addLine(to: CGPoint(x: 4, y: 6))
            path.closeSubpath()
            var check = Path()
            check.move(to: CGPoint(x: 8.5, y: 11.5))
            check.addLine(to: CGPoint(x: 11, y: 14))
            check.addLine(to: CGPoint(x: 15.5, y: 9))
            context.stroke(path, with: .color(color), style: strokeStyle)
            context.stroke(check, with: .color(color), style: strokeStyle)

        case .record:
            var outer = Path()
            outer.addEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
            var inner = Path()
            inner.addEllipse(in: CGRect(x: 9, y: 9, width: 6, height: 6))
            context.stroke(outer, with: .color(color), style: strokeStyle)
            context.fill(inner, with: .color(color))

        case .play:
            var path = Path()
            path.move(to: CGPoint(x: 9, y: 5))
            path.addLine(to: CGPoint(x: 20, y: 12))
            path.addLine(to: CGPoint(x: 9, y: 19))
            path.closeSubpath()
            context.fill(path, with: .color(color))

        case .pause:
            var line1 = Path()
            line1.move(to: CGPoint(x: 8, y: 5))
            line1.addLine(to: CGPoint(x: 8, y: 19))
            var line2 = Path()
            line2.move(to: CGPoint(x: 16, y: 5))
            line2.addLine(to: CGPoint(x: 16, y: 19))
            let pauseStyle = StrokeStyle(lineWidth: 3.5, lineCap: .round)
            context.stroke(line1, with: .color(color), style: pauseStyle)
            context.stroke(line2, with: .color(color), style: pauseStyle)

        case .more:
            let d: CGFloat = 2.4
            for x in [5.0, 12.0, 19.0] {
                var dot = Path()
                dot.addEllipse(in: CGRect(x: x - d/2, y: 12 - d/2, width: d, height: d))
                context.fill(dot, with: .color(color))
            }

        case .export:
            var path = Path()
            path.move(to: CGPoint(x: 12, y: 15))
            path.addLine(to: CGPoint(x: 12, y: 3))
            path.move(to: CGPoint(x: 8, y: 7))
            path.addLine(to: CGPoint(x: 12, y: 3))
            path.addLine(to: CGPoint(x: 16, y: 7))
            path.move(to: CGPoint(x: 5, y: 12))
            path.addLine(to: CGPoint(x: 5, y: 20))
            path.addLine(to: CGPoint(x: 19, y: 20))
            path.addLine(to: CGPoint(x: 19, y: 12))
            context.stroke(path, with: .color(color), style: strokeStyle)

        case .close:
            var path = Path()
            path.move(to: CGPoint(x: 6, y: 6))
            path.addLine(to: CGPoint(x: 18, y: 18))
            path.move(to: CGPoint(x: 6, y: 18))
            path.addLine(to: CGPoint(x: 18, y: 6))
            context.stroke(path, with: .color(color), style: strokeStyle)

        case .check:
            var circle = Path()
            circle.addEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
            var check = Path()
            check.move(to: CGPoint(x: 8, y: 12))
            check.addLine(to: CGPoint(x: 11, y: 15))
            check.addLine(to: CGPoint(x: 16, y: 9))
            context.stroke(circle, with: .color(color), style: strokeStyle)
            context.stroke(check, with: .color(color), style: strokeStyle)

        case .clock:
            var circle = Path()
            circle.addEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
            var hands = Path()
            hands.move(to: CGPoint(x: 12, y: 7))
            hands.addLine(to: CGPoint(x: 12, y: 12))
            hands.addLine(to: CGPoint(x: 15, y: 14))
            context.stroke(circle, with: .color(color), style: strokeStyle)
            context.stroke(hands, with: .color(color), style: strokeStyle)

        case .calendar:
            var rect = Path()
            rect.addRoundedRect(in: CGRect(x: 4, y: 5, width: 16, height: 15), cornerSize: CGSize(width: 2, height: 2))
            var lines = Path()
            lines.move(to: CGPoint(x: 8, y: 3)); lines.addLine(to: CGPoint(x: 8, y: 7))
            lines.move(to: CGPoint(x: 16, y: 3)); lines.addLine(to: CGPoint(x: 16, y: 7))
            lines.move(to: CGPoint(x: 4, y: 10)); lines.addLine(to: CGPoint(x: 20, y: 10))
            context.stroke(rect, with: .color(color), style: strokeStyle)
            context.stroke(lines, with: .color(color), style: strokeStyle)

        case .people:
            // Reference SVG: <circle cx="9" cy="8" r="3"/><path d="M3 20v-2a6 6 0 0 1 12 0v2m1-15a3 3 0 0 1 0 6m2 3a5 5 0 0 1 3 5"/>
            var head1 = Path()
            head1.addEllipse(in: CGRect(x: 6, y: 5, width: 6, height: 6))
            var body1 = Path()
            body1.move(to: CGPoint(x: 3, y: 20))
            body1.addLine(to: CGPoint(x: 3, y: 18))
            body1.addArc(center: CGPoint(x: 9, y: 18), radius: 6, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            body1.addLine(to: CGPoint(x: 15, y: 20))

            var head2 = Path()
            head2.addArc(center: CGPoint(x: 16, y: 8), radius: 3, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)

            var body2 = Path()
            body2.move(to: CGPoint(x: 18, y: 14))
            body2.addCurve(to: CGPoint(x: 21, y: 19), control1: CGPoint(x: 20, y: 15), control2: CGPoint(x: 21, y: 17))

            context.stroke(head1, with: .color(color), style: strokeStyle)
            context.stroke(body1, with: .color(color), style: strokeStyle)
            context.stroke(head2, with: .color(color), style: strokeStyle)
            context.stroke(body2, with: .color(color), style: strokeStyle)

        case .back:
            var path = Path()
            path.move(to: CGPoint(x: 14, y: 5))
            path.addLine(to: CGPoint(x: 7, y: 12))
            path.addLine(to: CGPoint(x: 14, y: 19))
            context.stroke(path, with: .color(color), style: strokeStyle)

        case .edit:
            var path = Path()
            path.move(to: CGPoint(x: 4, y: 16))
            path.addLine(to: CGPoint(x: 16, y: 4))
            path.addLine(to: CGPoint(x: 20, y: 8))
            path.addLine(to: CGPoint(x: 8, y: 20))
            path.addLine(to: CGPoint(x: 4, y: 20))
            path.closeSubpath()
            path.move(to: CGPoint(x: 13, y: 7))
            path.addLine(to: CGPoint(x: 17, y: 11))
            context.stroke(path, with: .color(color), style: strokeStyle)

        case .copy:
            var r = Path()
            r.addRoundedRect(in: CGRect(x: 8, y: 8, width: 12, height: 13), cornerSize: CGSize(width: 2, height: 2))
            var b = Path()
            b.move(to: CGPoint(x: 15, y: 8))
            b.addLine(to: CGPoint(x: 15, y: 3))
            b.addLine(to: CGPoint(x: 3, y: 3))
            b.addLine(to: CGPoint(x: 3, y: 15))
            b.addLine(to: CGPoint(x: 8, y: 15))
            context.stroke(r, with: .color(color), style: strokeStyle)
            context.stroke(b, with: .color(color), style: strokeStyle)

        case .mic:
            // Reference SVG: <rect x="9" y="3" width="6" height="12" rx="3"/><path d="M6 10v2a6 6 0 0 0 12 0v-2M12 18v3m-3 0h6"/>
            var capsule = Path()
            capsule.addRoundedRect(in: CGRect(x: 9, y: 3, width: 6, height: 12), cornerSize: CGSize(width: 3, height: 3))
            var stand = Path()
            stand.move(to: CGPoint(x: 6, y: 10))
            stand.addLine(to: CGPoint(x: 6, y: 12))
            stand.addCurve(to: CGPoint(x: 18, y: 12), control1: CGPoint(x: 6, y: 18), control2: CGPoint(x: 18, y: 18))
            stand.addLine(to: CGPoint(x: 18, y: 10))
            stand.move(to: CGPoint(x: 12, y: 18))
            stand.addLine(to: CGPoint(x: 12, y: 21))
            stand.move(to: CGPoint(x: 9, y: 21))
            stand.addLine(to: CGPoint(x: 15, y: 21))
            context.stroke(capsule, with: .color(color), style: strokeStyle)
            context.stroke(stand, with: .color(color), style: strokeStyle)

        case .mute:
            // Reference SVG: <path d="m3 3 18 18M9 9v3a3 3 0 0 0 5 2M9 5a3 3 0 0 1 6 0v6M6 10v2a6 6 0 0 0 11 3M12 18v3m-3 0h6"/>
            var strike = Path()
            strike.move(to: CGPoint(x: 3, y: 3))
            strike.addLine(to: CGPoint(x: 21, y: 21))

            var bowl = Path()
            bowl.move(to: CGPoint(x: 9, y: 9))
            bowl.addLine(to: CGPoint(x: 9, y: 12))
            bowl.addCurve(to: CGPoint(x: 14, y: 14), control1: CGPoint(x: 9, y: 13.5), control2: CGPoint(x: 11.5, y: 14))

            var top = Path()
            top.move(to: CGPoint(x: 9, y: 5))
            top.addArc(center: CGPoint(x: 12, y: 5), radius: 3, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            top.addLine(to: CGPoint(x: 15, y: 11))

            var cradle = Path()
            cradle.move(to: CGPoint(x: 6, y: 10))
            cradle.addLine(to: CGPoint(x: 6, y: 12))
            cradle.addCurve(to: CGPoint(x: 17, y: 15), control1: CGPoint(x: 6, y: 16.5), control2: CGPoint(x: 13, y: 16.5))

            var stem = Path()
            stem.move(to: CGPoint(x: 12, y: 18))
            stem.addLine(to: CGPoint(x: 12, y: 21))
            stem.move(to: CGPoint(x: 9, y: 21))
            stem.addLine(to: CGPoint(x: 15, y: 21))

            context.stroke(strike, with: .color(color), style: strokeStyle)
            context.stroke(bowl, with: .color(color), style: strokeStyle)
            context.stroke(top, with: .color(color), style: strokeStyle)
            context.stroke(cradle, with: .color(color), style: strokeStyle)
            context.stroke(stem, with: .color(color), style: strokeStyle)

        case .stop:
            // Reference SVG: <rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor" stroke="none"/>
            var square = Path()
            square.addRoundedRect(in: CGRect(x: 6, y: 6, width: 12, height: 12), cornerSize: CGSize(width: 2, height: 2))
            context.fill(square, with: .color(color))

        case .wave:
            var lines = Path()
            lines.move(to: CGPoint(x: 4, y: 10)); lines.addLine(to: CGPoint(x: 4, y: 14))
            lines.move(to: CGPoint(x: 8, y: 6)); lines.addLine(to: CGPoint(x: 8, y: 18))
            lines.move(to: CGPoint(x: 12, y: 3)); lines.addLine(to: CGPoint(x: 12, y: 21))
            lines.move(to: CGPoint(x: 16, y: 6)); lines.addLine(to: CGPoint(x: 16, y: 18))
            lines.move(to: CGPoint(x: 20, y: 10)); lines.addLine(to: CGPoint(x: 20, y: 14))
            context.stroke(lines, with: .color(color), style: strokeStyle)

        case .warning:
            var tri = Path()
            tri.move(to: CGPoint(x: 12, y: 3))
            tri.addLine(to: CGPoint(x: 22, y: 20))
            tri.addLine(to: CGPoint(x: 2, y: 20))
            tri.closeSubpath()
            var mark = Path()
            mark.move(to: CGPoint(x: 12, y: 9)); mark.addLine(to: CGPoint(x: 12, y: 14))
            var dot = Path()
            dot.addEllipse(in: CGRect(x: 11, y: 16.5, width: 2, height: 2))
            context.stroke(tri, with: .color(color), style: strokeStyle)
            context.stroke(mark, with: .color(color), style: strokeStyle)
            context.fill(dot, with: .color(color))

        case .retry:
            var arc = Path()
            arc.addArc(center: CGPoint(x: 12, y: 12), radius: 8, startAngle: .degrees(-150), endAngle: .degrees(120), clockwise: false)
            var arrow = Path()
            arrow.move(to: CGPoint(x: 4, y: 4))
            arrow.addLine(to: CGPoint(x: 4, y: 10))
            arrow.addLine(to: CGPoint(x: 10, y: 10))
            context.stroke(arc, with: .color(color), style: strokeStyle)
            context.stroke(arrow, with: .color(color), style: strokeStyle)
        }
    }
}


import MeetingCompanionCore

public struct TranscriptionProgressView: View {
    public let progress: TranscriptionProgress

    public init(progress: TranscriptionProgress) {
        self.progress = progress
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let step = progress.step, let steps = progress.steps, let completed = progress.completedSteps {
                HStack {
                    Text("Обработка записи")
                    Spacer(minLength: 4)
                    Text("Этап \(step) из \(steps)").monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption)
                VStack(spacing: 4) {
                    bar(Double(completed) / Double(steps), color: Color(nsColor: .systemBlue), height: 6)
                        .accessibilityLabel("Завершено этапов")
                        .accessibilityValue("\(completed) из \(steps)")
                    if let fraction = progress.stageFraction {
                        bar(fraction, color: Color(nsColor: .systemPink), height: 2)
                            .accessibilityLabel("Текущий этап")
                            .accessibilityValue("\(progress.completed) из \(progress.total)")
                    }
                }
            }
            Text(progress.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func bar(_ fraction: Double, color: Color, height: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Color(nsColor: .controlColor))
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: geometry.size.width * fraction)
                }
        }.frame(height: height)
    }
}


public struct MeetingOverlaySurface: ViewModifier {
    public var capsule: Bool

    public init(capsule: Bool = false) {
        self.capsule = capsule
    }

    @ViewBuilder public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: capsule ? 36 : 24)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 1))
        }
    }
}
