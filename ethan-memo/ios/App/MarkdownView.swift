import SwiftUI

/// 위키 본문 렌더러: 소제목·목록·체크박스·인용·표·코드·링크 카드·[[링크]]·#태그
/// 링크는 haru-wiki:// 주소로 바뀌어 openURL에서 처리됨
struct MarkdownView: View {
    let text: String
    var exists: (String) -> Bool = { _ in true }
    var onToggle: (Int) -> Void = { _ in }

    enum Block {
        case heading(Int, String)
        case paragraph([String])
        case bullets([String])
        case tasks([(line: Int, done: Bool, text: String)])
        case ordered([String])
        case quote([String])
        case code(String)
        case rule
        case table([String], [[String]])
        case card(URL)
    }

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            let heads = blocks.compactMap { b -> (Int, String)? in if case .heading(let l, let t) = b { return (l, t) }; return nil }
            if heads.count >= 3 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("목차").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(heads.enumerated()), id: \.offset) { _, h in
                        Text(WikiText.plain(h.1).replacingOccurrences(of: "**", with: ""))
                            .font(.subheadline)
                            .foregroundStyle(h.0 == 1 ? Color.primary : Color.secondary)
                            .padding(.leading, CGFloat(h.0 - 1) * 12)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemFill)))
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                view(for: b)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for b: Block) -> some View {
        switch b {
        case .heading(let lv, let t):
            Text(inline(t))
                .font(lv == 1 ? .title3.weight(.bold) : lv == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, lv == 1 ? 8 : 4)
        case .paragraph(let lines):
            Text(inline(lines.joined(separator: "\n")))
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(t))
                    }
                }
            }
        case .tasks(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .top, spacing: 9) {
                        Button { onToggle(t.line) } label: {
                            Image(systemName: t.done ? "checkmark.square.fill" : "square")
                                .foregroundStyle(t.done ? Color.green : Color.secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        Text(inline(t.text))
                            .strikethrough(t.done)
                            .foregroundStyle(t.done ? .secondary : .primary)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(inline(t))
                    }
                }
            }
        case .quote(let lines):
            Text(inline(lines.joined(separator: "\n")))
                .padding(.vertical, 10).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemFill))
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        case .code(let c):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(c).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill)))
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let head, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(head.enumerated()), id: \.offset) { _, c in
                            Text(inline(c)).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
                                .background(Color(.tertiarySystemFill))
                                .border(Color(.separator), width: 0.5)
                        }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            ForEach(0..<head.count, id: \.self) { k in
                                Text(inline(k < r.count ? r[k] : "")).font(.subheadline)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
                                    .border(Color(.separator), width: 0.5)
                            }
                        }
                    }
                }
            }
        case .card(let url):
            Link(destination: url) {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?domain=\(url.host ?? "")&sz=64")) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text((url.host ?? "").replacingOccurrences(of: "www.", with: ""))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator)))
            }
        }
    }

    // MARK: - 인라인

    private func inline(_ s: String) -> AttributedString {
        var t = s
        // [[제목|별칭]] → 링크
        t = Self.replace(t, #"\[\[([^\[\]\n|]+)(?:\|([^\[\]\n]+))?\]\]"#) { g in
            let target = g[1].trimmingCharacters(in: .whitespaces)
            let label = (g[2].isEmpty ? g[1] : g[2]).trimmingCharacters(in: .whitespaces)
            if WikiText.isDate(target), let d = WikiText.date(target) {
                return "[\(Self.mdLabel(Fmt.short(d)))](haru-wiki://date?d=\(target))"
            }
            let mark = exists(target) ? "" : " ⁺"
            return "[\(Self.mdLabel(label))\(mark)](haru-wiki://open?t=\(Self.pct(target)))"
        }
        // 맨 URL → 도메인 링크
        t = Self.replace(t, #"(?<![\(\[<])(https?://[^\s<>()\]]*[^\s<>().,!?;:'"\]])"#) { g in
            let host = URL(string: g[1])?.host?.replacingOccurrences(of: "www.", with: "") ?? g[1]
            return "[\(Self.mdLabel(host))↗](\(g[1]))"
        }
        // #태그
        t = Self.replace(t, #"(^|\s)#([0-9A-Za-z가-힣_\-]+)"#) { g in
            "\(g[1])[#\(g[2])](haru-wiki://tag?t=\(Self.pct(g[2])))"
        }
        if let a = try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return a
        }
        return AttributedString(WikiText.plain(s))
    }

    private static func pct(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
    private static func mdLabel(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    /// 정규식 치환 (그룹 배열을 받아 대체 문자열 생성; 없는 그룹은 빈 문자열)
    static func replace(_ text: String, _ pattern: String, _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            var g: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                g.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out = out.replacingCharacters(in: m.range, with: f(g)) as NSString
        }
        return out as String
    }

    // MARK: - 블록

    static func parse(_ text: String) -> [Block] {
        let L = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var out: [Block] = []
        var para: [String] = []
        var i = 0
        func flush() { if !para.isEmpty { out.append(.paragraph(para)); para = [] } }
        func m(_ s: String, _ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }
        func strip(_ s: String, _ p: String) -> String { s.replacingOccurrences(of: p, with: "", options: .regularExpression) }
        func cells(_ r: String) -> [String] {
            var s = r.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s.removeFirst() }
            if s.hasSuffix("|") { s.removeLast() }
            return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while i < L.count {
            let ln = L[i]
            if ln.hasPrefix("```") {
                flush(); var buf: [String] = []; i += 1
                while i < L.count && !L[i].hasPrefix("```") { buf.append(L[i]); i += 1 }
                i += 1; out.append(.code(buf.joined(separator: "\n"))); continue
            }
            if ln.trimmingCharacters(in: .whitespaces).isEmpty { flush(); i += 1; continue }
            if let r = ln.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
                flush()
                let lv = ln[r].filter { $0 == "#" }.count
                out.append(.heading(lv, String(ln[r.upperBound...]))); i += 1; continue
            }
            if m(ln, #"^\s*(---+|\*\*\*+)\s*$"#) { flush(); out.append(.rule); i += 1; continue }
            if m(ln, #"^>\s?"#) {
                flush(); var buf: [String] = []
                while i < L.count && m(L[i], #"^>\s?"#) { buf.append(strip(L[i], #"^>\s?"#)); i += 1 }
                out.append(.quote(buf)); continue
            }
            if m(ln, #"^\s*\|.*\|\s*$"#) && i + 1 < L.count && m(L[i + 1], #"^\s*\|?\s*:?-{2,}"#) {
                flush(); let head = cells(ln); i += 2; var rows: [[String]] = []
                while i < L.count && m(L[i], #"^\s*\|.*\|\s*$"#) { rows.append(cells(L[i])); i += 1 }
                out.append(.table(head, rows)); continue
            }
            if m(ln, #"^\s*[-*+]\s+\[( |x|X)\]"#) {
                flush(); var buf: [(line: Int, done: Bool, text: String)] = []
                while i < L.count && m(L[i], #"^\s*[-*+]\s+\[( |x|X)\]"#) {
                    let done = m(L[i], #"^\s*[-*+]\s+\[(x|X)\]"#)
                    buf.append((i, done, strip(L[i], #"^\s*[-*+]\s+\[( |x|X)\]\s*"#))); i += 1
                }
                out.append(.tasks(buf)); continue
            }
            if m(ln, #"^\s*[-*+]\s+"#) {
                flush(); var buf: [String] = []
                while i < L.count && m(L[i], #"^\s*[-*+]\s+"#) && !m(L[i], #"^\s*[-*+]\s+\[( |x|X)\]"#) {
                    buf.append(strip(L[i], #"^\s*[-*+]\s+"#)); i += 1
                }
                out.append(.bullets(buf)); continue
            }
            if m(ln, #"^\s*\d+[.)]\s+"#) {
                flush(); var buf: [String] = []
                while i < L.count && m(L[i], #"^\s*\d+[.)]\s+"#) { buf.append(strip(L[i], #"^\s*\d+[.)]\s+"#)); i += 1 }
                out.append(.ordered(buf)); continue
            }
            let tr = ln.trimmingCharacters(in: .whitespaces)
            if m(tr, #"^https?://\S+$"#), let u = URL(string: tr) { flush(); out.append(.card(u)); i += 1; continue }
            para.append(ln); i += 1
        }
        flush()
        return out
    }
}
