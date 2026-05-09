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

                    Text(MarkdownText.attributed(content))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .textSelection(.enabled)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// Helpers for rendering MedGemma's markdown output.
///
/// MedGemma is prompted to return **bold**, *italic*, and occasional emoji.
/// Without an attributed-markdown parse, those asterisks would show up as
/// literal characters in the UI. `.inlineOnlyPreservingWhitespace` is the
/// right interpretation because we render section bodies in cards: we want
/// inline emphasis to format, but we don't want the parser to swallow
/// blank lines or treat numbered headers as block markdown.
enum MarkdownText {
    static func attributed(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: raw, options: options))
            ?? AttributedString(raw)
    }
}
