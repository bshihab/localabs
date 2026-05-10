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

/// Renders MedGemma's markdown output as formatted text + bullets +
/// tables. Splits the input into block-level chunks (paragraphs, bullet
/// rows, blank lines, markdown tables) and renders each appropriately.
/// Inline emphasis (**bold**, *italic*, `code`, links) inside any block
/// is parsed via SwiftUI's LocalizedStringKey initializer, which is the
/// most reliable inline-markdown path on iOS.
///
/// `.textSelection(.enabled)` is applied per-block so long-press-and-drag
/// can grab a single sentence (or table cell) without grabbing the whole
/// card.
struct MarkdownBody: View {
    let content: String

    init(_ content: String) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks.indices, id: \.self) { idx in
                blockView(for: blocks[idx])
            }
        }
    }

    @ViewBuilder
    private func blockView(for block: Block) -> some View {
        switch block {
        case .blank:
            Color.clear.frame(height: 6)

        case .paragraph(let line):
            Text(LocalizedStringKey(line))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let body):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey(body))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .table(let rows):
            // Horizontally scrollable so wide tables don't blow out the
            // chat bubble / card width. First row is treated as the
            // header (semibold + subtle blue tint).
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(rows.indices, id: \.self) { rIdx in
                        GridRow {
                            let isHeader = rIdx == 0
                            ForEach(rows[rIdx].indices, id: \.self) { cIdx in
                                Text(LocalizedStringKey(rows[rIdx][cIdx]))
                                    .font(.system(size: 13))
                                    .fontWeight(isHeader ? .semibold : .regular)
                                    .textSelection(.enabled)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 6)
                                    .frame(minHeight: 24, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(isHeader ? Color.blue.opacity(0.10) : Color.clear)
                                    )
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private enum Block {
        case blank
        case paragraph(String)
        case bullet(String)
        case table([[String]])
    }

    /// Computed per-render — cheap (~µs for chat-message-sized inputs)
    /// and avoids stashing parsed state that'd need invalidation when
    /// `content` changes for streaming output.
    private var blocks: [Block] {
        parseBlocks(content)
    }

    private func parseBlocks(_ raw: String) -> [Block] {
        var result: [Block] = []
        let lines = raw.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty {
                result.append(.blank)
                i += 1
                continue
            }
            // Markdown table block: consecutive lines starting AND ending
            // with `|`. Collect them, parse as a table; if the structure
            // doesn't look table-like, fall back to paragraph rendering
            // for each line.
            if line.hasPrefix("|") && line.hasSuffix("|") {
                var tableLines: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.hasPrefix("|") && l.hasSuffix("|") {
                        tableLines.append(l)
                        i += 1
                    } else {
                        break
                    }
                }
                if let rows = parseMarkdownTable(tableLines) {
                    result.append(.table(rows))
                } else {
                    for tl in tableLines {
                        result.append(.paragraph(tl))
                    }
                }
                continue
            }
            // Bullet line: `- foo` or `* foo`.
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(.bullet(String(line.dropFirst(2))))
                i += 1
                continue
            }
            result.append(.paragraph(line))
            i += 1
        }
        return result
    }

    /// Parses a contiguous block of pipe-delimited markdown table lines
    /// into a rectangular `[[String]]` (rows of cells, all rows padded
    /// to the same column count). Skips the divider line (e.g. `|---|---|`)
    /// since it carries alignment info we don't render. Returns nil if
    /// the lines don't look like a real table — the caller falls back to
    /// rendering each line as a paragraph.
    private func parseMarkdownTable(_ lines: [String]) -> [[String]]? {
        guard lines.count >= 2 else { return nil }
        var rows: [[String]] = []
        for line in lines {
            // A divider line is composed only of |, -, :, and spaces.
            // Skip it when assembling row data.
            let isDivider = line.allSatisfy { ch in
                ch == "|" || ch == "-" || ch == ":" || ch == " "
            } && line.contains("-")
            if isDivider { continue }
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            let cells = trimmed
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            rows.append(cells)
        }
        // Need at least header + 1 data row to call it a table.
        guard rows.count >= 2 else { return nil }
        // Pad shorter rows with empty cells so the Grid doesn't get a
        // jagged shape.
        let maxCols = rows.map(\.count).max() ?? 0
        return rows.map { row -> [String] in
            var r = row
            while r.count < maxCols { r.append("") }
            return r
        }
    }
}
