import Foundation
import UniformTypeIdentifiers

enum InlineLocalAssets {

    struct Attachment: Equatable {
        let data: Data
        /// Lowercased file extension of the source (e.g. `"png"`). Empty if
        /// the source URL had none. Lets the caller derive a UTType.
        let pathExtension: String
    }

    struct Result {
        let html: String
        let attachments: [String: Attachment]
    }

    static func rewriteRelativeImages(
        html: String,
        baseDirectory: URL,
        reader: (URL) throws -> Data,
        perImageByteCap: Int = 4 * 1024 * 1024,
        cumulativeByteCap: Int = 8 * 1024 * 1024
    ) -> Result {
        let nsHtml = html as NSString
        let matches = imgSrcRegex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHtml.length)
        )
        guard !matches.isEmpty else {
            return Result(html: html, attachments: [:])
        }

        var attachments: [String: Attachment] = [:]
        var srcToCID: [String: String] = [:]
        var cumulativeBytes = 0
        var output = ""
        output.reserveCapacity(html.count)
        var cursor = 0

        for match in matches {
            output += nsHtml.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))

            let prefix = nsHtml.substring(with: match.range(at: 1))
            let src = nsHtml.substring(with: match.range(at: 2))
            let suffix = nsHtml.substring(with: match.range(at: 3))

            let replacement: String
            if let existingCID = srcToCID[src] {
                replacement = "\(prefix)cid:\(existingCID)\(suffix)"
            } else if let resolved = resolveRelative(src: src, baseDirectory: baseDirectory),
                      let data = try? reader(resolved),
                      data.count <= perImageByteCap,
                      cumulativeBytes + data.count <= cumulativeByteCap {
                let cid = "md-asset-\(attachments.count)"
                attachments[cid] = Attachment(
                    data: data,
                    pathExtension: resolved.pathExtension.lowercased()
                )
                srcToCID[src] = cid
                cumulativeBytes += data.count
                replacement = "\(prefix)cid:\(cid)\(suffix)"
            } else {
                replacement = nsHtml.substring(with: match.range)
            }

            output += replacement
            cursor = match.range.location + match.range.length
        }
        output += nsHtml.substring(from: cursor)

        return Result(html: output, attachments: attachments)
    }

    static func dataURLHTML(from result: Result) -> String {
        var html = result.html
        for (contentID, attachment) in result.attachments.sorted(by: { $0.key < $1.key }) {
            let mimeType = UTType(filenameExtension: attachment.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            let dataURL = "data:\(mimeType);base64,\(attachment.data.base64EncodedString())"
            html = html.replacingOccurrences(of: "cid:\(contentID)", with: dataURL)
        }
        return html
    }

    // Matches the double-quoted image tags emitted by MarkdownHTML's renderer.
    private static let imgSrcRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(<img\b[^>]*?\bsrc=")([^"]*)(")"#,
            options: [.caseInsensitive]
        )
    }()

    /// Returns nil for srcs that should not be rewritten (absolute URLs,
    /// fragment refs, host-absolute paths, empty values).
    private static func resolveRelative(src: String, baseDirectory: URL) -> URL? {
        guard !src.isEmpty else { return nil }
        if src.hasPrefix("#") || src.hasPrefix("/") { return nil }
        if hasURLScheme(src) { return nil }

        // CommonMark renderers percent-encode spaces in image targets;
        // FileManager wants real paths.
        let decoded = src.removingPercentEncoding ?? src
        guard !decoded.isEmpty else { return nil }
        if decoded.hasPrefix("#") || decoded.hasPrefix("/") { return nil }
        if hasURLScheme(decoded) { return nil }

        let base = baseDirectory.standardizedFileURL
        let candidate = URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
        guard isDescendantOrSame(candidate, of: base) else { return nil }
        return candidate
    }

    private static func hasURLScheme(_ value: String) -> Bool {
        // Reject anything that looks like `scheme:` where scheme is
        // `[a-z][a-z0-9+.-]*` (RFC 3986). Stops short of `:` so paths like
        // `images/foo:bar.png` are still treated as relative.
        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = value[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { c in
            c.isLetter || c.isNumber || c == "+" || c == "." || c == "-"
        }
    }

    private static func isDescendantOrSame(_ candidate: URL, of baseDirectory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let basePath = baseDirectory.standardizedFileURL.path
        return candidatePath == basePath || candidatePath.hasPrefix(basePath + "/")
    }
}

enum QuickLookHTML {
    private static let interactionStyle = """
    <style id="md-quick-look-interaction">
    html,
    body,
    article.markdown-body {
        cursor: text;
    }
    a[href],
    button:not(:disabled),
    input:not(:disabled),
    select:not(:disabled),
    textarea:not(:disabled),
    summary,
    [role="button"] {
        cursor: pointer;
    }
    </style>
    """

    static func addingNativeTextCursor(to html: String) -> String {
        guard let headEnd = html.range(of: "</head>", options: .caseInsensitive) else {
            return interactionStyle + "\n" + html
        }

        var output = html
        output.insert(contentsOf: interactionStyle + "\n", at: headEnd.lowerBound)
        return output
    }
}
