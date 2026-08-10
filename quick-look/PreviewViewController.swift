//
//  PreviewViewController.swift
//  quick-look
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import Quartz
import WebKit

private final class CursorRegionMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: QuickLookWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        owner?.updateCursorRegions(from: message.body)
    }
}

private final class QuickLookWebView: WKWebView {
    private struct CursorRegion {
        let rect: NSRect
        let cursor: NSCursor
    }

    private static let cursorRegionMessageName = "mdPreviewCursorRegions"
    private var cursorRegions: [CursorRegion] = []

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        let messageProxy = CursorRegionMessageProxy()
        configuration.userContentController.add(
            messageProxy,
            name: Self.cursorRegionMessageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.cursorRegionReportingScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        super.init(frame: frame, configuration: configuration)
        messageProxy.owner = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for region in cursorRegions {
            addCursorRect(region.rect, cursor: region.cursor)
        }
    }

    fileprivate func updateCursorRegions(from body: Any) {
        guard let rows = body as? [Any] else { return }

        cursorRegions = rows.compactMap { row in
            guard let values = row as? [Any],
                  values.count == 5,
                  let kind = values[0] as? String,
                  let x = (values[1] as? NSNumber)?.doubleValue,
                  let y = (values[2] as? NSNumber)?.doubleValue,
                  let width = (values[3] as? NSNumber)?.doubleValue,
                  let height = (values[4] as? NSNumber)?.doubleValue,
                  [x, y, width, height].allSatisfy(\.isFinite),
                  width > 0,
                  height > 0 else { return nil }

            let localY = isFlipped ? y : bounds.height - y - height
            let rect = NSRect(x: x, y: localY, width: width, height: height)
                .intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { return nil }

            let cursor: NSCursor
            switch kind {
            case "text":
                cursor = .iBeam
            case "pointer":
                cursor = .pointingHand
            default:
                return nil
            }
            return CursorRegion(rect: rect, cursor: cursor)
        }

        window?.invalidateCursorRects(for: self)
    }

    // A Quick Look preview is hosted through ViewBridge. WebKit's direct
    // cursor update is not forwarded reliably across that remote-window
    // boundary, while AppKit cursor rects are. Cache DOM layout rectangles
    // when layout changes, then only project that cache while scrolling; no
    // mouse-move listener or per-hover DOM hit testing is involved.
    private static let cursorRegionReportingScript = """
    (() => {
        const handler = window.webkit?.messageHandlers?.mdPreviewCursorRegions;
        if (!handler) return;

        const pointerSelector = [
            'a[href]',
            'button:not([disabled])',
            'summary',
            '[role="button"]',
            'input[type="checkbox"]:not([disabled])',
            'input[type="radio"]:not([disabled])',
            '.md-code-copy'
        ].join(',');
        const textExclusionSelector = [
            'a', 'button', 'input', 'select', 'textarea', 'summary',
            '[role="button"]', '[contenteditable="true"]', '.md-code-copy'
        ].join(',');

        let cachedRegions = [];
        let layoutFrame = null;
        let viewportFrame = null;
        let resizeObserver = null;
        let observedArticle = null;

        const isRenderable = (element) => {
            const style = getComputedStyle(element);
            return style.display !== 'none'
                && style.visibility !== 'hidden'
                && style.pointerEvents !== 'none';
        };

        const appendDocumentRect = (kind, rect, scrollX, scrollY) => {
            if (rect.width <= 0 || rect.height <= 0) return;
            cachedRegions.push([
                kind,
                rect.left + scrollX,
                rect.top + scrollY,
                rect.width,
                rect.height
            ]);
        };

        const postVisibleRegions = () => {
            viewportFrame = null;
            const scrollX = window.scrollX;
            const scrollY = window.scrollY;
            const viewportWidth = document.documentElement.clientWidth;
            const viewportHeight = document.documentElement.clientHeight;
            const visible = [];

            for (const [kind, documentX, documentY, width, height] of cachedRegions) {
                const x = documentX - scrollX;
                const y = documentY - scrollY;
                if (x + width <= 0 || y + height <= 0
                    || x >= viewportWidth || y >= viewportHeight) continue;
                visible.push([kind, x, y, width, height]);
            }
            handler.postMessage(visible);
        };

        const scheduleViewportProjection = () => {
            if (viewportFrame !== null) return;
            viewportFrame = requestAnimationFrame(postVisibleRegions);
        };

        const rebuildLayoutCache = () => {
            layoutFrame = null;
            const article = document.querySelector('article.markdown-body');
            cachedRegions = [];
            if (!article) {
                handler.postMessage([]);
                return;
            }

            if (observedArticle !== article && window.ResizeObserver) {
                resizeObserver?.disconnect();
                resizeObserver = new ResizeObserver(scheduleLayoutRebuild);
                resizeObserver.observe(article);
                observedArticle = article;
            }

            const scrollX = window.scrollX;
            const scrollY = window.scrollY;

            for (const element of article.querySelectorAll(pointerSelector)) {
                if (!isRenderable(element)) continue;
                for (const rect of element.getClientRects()) {
                    appendDocumentRect('pointer', rect, scrollX, scrollY);
                }
            }

            const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
                if (!node.nodeValue || !node.nodeValue.trim()) continue;
                const parent = node.parentElement;
                if (!parent || parent.closest(textExclusionSelector) || !isRenderable(parent)) {
                    continue;
                }

                const style = getComputedStyle(parent);
                if (style.userSelect === 'none' || style.webkitUserSelect === 'none') continue;

                const range = document.createRange();
                range.selectNodeContents(node);
                for (const rect of range.getClientRects()) {
                    appendDocumentRect('text', rect, scrollX, scrollY);
                }
            }

            postVisibleRegions();
        };

        function scheduleLayoutRebuild() {
            if (layoutFrame !== null) return;
            layoutFrame = requestAnimationFrame(rebuildLayoutCache);
        }

        addEventListener('scroll', scheduleViewportProjection, true);
        addEventListener('resize', scheduleLayoutRebuild);
        document.addEventListener('DOMContentLoaded', scheduleLayoutRebuild, { once: true });
        document.addEventListener('load', scheduleLayoutRebuild, true);
        document.addEventListener('toggle', scheduleLayoutRebuild, true);
        for (const eventName of [
            'md-preview-math-rendered',
            'md-preview-hljs-rendered',
            'md-preview-mermaid-rendered'
        ]) {
            addEventListener(eventName, scheduleLayoutRebuild);
        }
        document.fonts?.ready.then(scheduleLayoutRebuild);
        scheduleLayoutRebuild();
    })();
    """
}

final class PreviewViewController: NSViewController, QLPreviewingController {
    private var webView: QuickLookWebView!

    override func loadView() {
        webView = QuickLookWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        view = webView
        preferredContentSize = NSSize(
            width: MarkdownHTML.preferredPageWidth,
            height: MarkdownHTML.preferredPageWidth
        )
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let appearanceMode = AppearanceMode.current
        let colorScheme: MarkdownHTML.ColorScheme
        switch appearanceMode {
        case .automatic:
            let appearance = NSApplication.shared.effectiveAppearance
            let systemIsDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            colorScheme = appearanceMode.resolvedColorScheme(systemIsDark: systemIsDark)
        case .light:
            colorScheme = .light
        case .dark:
            colorScheme = .dark
        }

        let renderedHTML = MarkdownHTML.makeHTML(
            from: text,
            allowsScroll: true,
            colorScheme: colorScheme
        )
        let baseDirectory = url.deletingLastPathComponent()
        let rewrite = InlineLocalAssets.rewriteRelativeImages(
            html: renderedHTML,
            baseDirectory: baseDirectory,
            reader: { try Data(contentsOf: $0) }
        )

        loadViewIfNeeded()
        webView.loadHTMLString(
            InlineLocalAssets.dataURLHTML(from: rewrite),
            baseURL: baseDirectory
        )
    }
}
