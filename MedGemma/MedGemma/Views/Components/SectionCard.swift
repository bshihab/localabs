import SwiftUI

/// Liquid-Glass collapsible card for each AI insight section on the Dashboard.
struct SectionCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let content: String
    var defaultExpanded: Bool = false

    @State private var isExpanded: Bool

    init(icon: String, iconColor: Color, title: String, content: String, defaultExpanded: Bool = false) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.content = content
        self.defaultExpanded = defaultExpanded
        self._isExpanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        if content.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(iconColor.opacity(0.16))
                                .frame(width: 40, height: 40)
                            Image(systemName: icon)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(iconColor)
                        }

                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)

                        Spacer()

                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                        .padding(.horizontal, 18)

                    MarkdownBody(content)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// Renders MedGemma's markdown output as proper formatted text. Splits on
/// newlines and feeds each line through SwiftUI's LocalizedStringKey
/// initializer, which is the most reliable way to get inline markdown
/// (**bold**, *italic*, `code`) parsed in SwiftUI — the AttributedString
/// markdown initializer has subtle parsing quirks (especially around
/// whitespace), and Text(String) doesn't parse markdown at all.
///
/// Lines starting with `- ` or `* ` render as proper bulleted rows with a
/// • marker and hanging indent so wrapped text aligns under the first
/// character of the bullet.
///
/// `.textSelection(.enabled)` is applied per-line so long-press-and-drag
/// can grab a single sentence without selecting the whole card.
struct MarkdownBody: View {
    let content: String

    init(_ content: String) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Color.clear.frame(height: 6)
                } else if let bullet = bulletText(line) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(LocalizedStringKey(bullet))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(LocalizedStringKey(line))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Returns the body of a bullet line if `line` starts with a markdown
    /// bullet marker (`- ` or `* `), otherwise nil.
    private func bulletText(_ line: String) -> String? {
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        return nil
    }
}
