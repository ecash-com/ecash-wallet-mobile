// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A small RSS 2.0 item reader for `news.ecash.com/rss.xml`.
///
/// **Why not `XMLParser`:** on non-Apple platforms it lives in `FoundationXML`, and whether the Fuse
/// Android SDK ships that is unverified (`docs/dashboard-plan.md` S1). This feed is machine-generated
/// and regular, so reading `<item>` blocks directly is simpler than a platform question with a crash at
/// the end of it. It handles what this feed uses: CDATA, the five XML entities plus numeric
/// references, attributes on `<source>`, and repeated `<category>`.
enum RSSFeedParser {
    static func items(from xml: String) -> [EcosystemNewsItem] {
        var result: [EcosystemNewsItem] = []
        var parts = xml.components(separatedBy: "<item>")
        guard parts.count > 1 else { return [] }
        parts.removeFirst()   // the channel header
        for part in parts {
            let block = part.components(separatedBy: "</item>")[0]
            guard let title = element("title", in: block), !title.isEmpty else { continue }
            let link = element("link", in: block) ?? ""
            let guid = element("guid", in: block)
            let id = guid ?? link
            guard !id.isEmpty else { continue }
            result.append(EcosystemNewsItem(
                id: id, title: title,
                link: link.isEmpty ? (guid ?? "") : link,
                publishedAt: element("pubDate", in: block).flatMap(parseDate),
                summary: element("description", in: block) ?? "",
                source: element("source", in: block),
                categories: elements("category", in: block)))
        }
        return result
    }

    /// The text of the first `<name …>…</name>` in `block`, decoded and trimmed.
    static func element(_ name: String, in block: String) -> String? {
        elements(name, in: block).first
    }

    static func elements(_ name: String, in block: String) -> [String] {
        var out: [String] = []
        var rest = Substring(block)
        while let open = rest.range(of: "<\(name)") {
            // The tag must end right after the name (`<source url=…>` yes, `<sourceId>` no).
            let afterName = rest[open.upperBound...]
            guard let next = afterName.first, next == ">" || next == " " || next == "/" else {
                rest = afterName
                continue
            }
            guard let tagEnd = afterName.range(of: ">") else { break }
            if afterName[..<tagEnd.lowerBound].hasSuffix("/") {   // self-closing: empty
                rest = afterName[tagEnd.upperBound...]
                continue
            }
            let body = afterName[tagEnd.upperBound...]
            guard let close = body.range(of: "</\(name)>") else { break }
            out.append(decode(String(body[..<close.lowerBound])))
            rest = body[close.upperBound...]
        }
        return out
    }

    /// CDATA unwrapped, entities decoded, whitespace trimmed.
    static func decode(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<![CDATA["), text.hasSuffix("]]>") {
            text = String(text.dropFirst(9).dropLast(3))
            return text.trimmingCharacters(in: .whitespacesAndNewlines)   // CDATA is literal
        }
        return decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 10 {
                let entity = String(s[s.index(after: i)..<semi])
                if let decoded = entityValue(entity) {
                    out += decoded
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static func entityValue(_ entity: String) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            var code: UInt32? = nil
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                code = UInt32(entity.dropFirst(2), radix: 16)
            } else if entity.hasPrefix("#") {
                code = UInt32(entity.dropFirst())
            }
            guard let code, let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
    }

    /// RFC 822 dates as RSS writes them: `Mon, 05 Oct 2026 12:00:00 GMT` (weekday optional).
    static func parseDate(_ text: String) -> Int64? {
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return Int64(date.timeIntervalSince1970) }
        }
        return nil
    }
}
