//
//  PreviewViewController.swift
//  quick-look
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import Quartz
import WebKit

private final class CursorRectMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: QuickLookWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        owner?.updateTextCursorRects(from: message.body)
    }
}

private final class QuickLookWebView: WKWebView {
    private static let cursorRectMessageName = "mdPreviewTextCursorRects"
    private var textCursorRects: [NSRect] = []

    override var acceptsFirstResponder: Bool { true }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        let messageProxy = CursorRectMessageProxy()
        configuration.userContentController.add(
            messageProxy,
            name: QuickLookWebView.cursorRectMessageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: QuickLookWebView.cursorRectReportingScript,
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
        for rect in textCursorRects {
            addCursorRect(rect, cursor: .iBeam)
        }
    }

    fileprivate func updateTextCursorRects(from body: Any) {
        guard let rows = body as? [Any] else { return }
        let viewHeight = bounds.height
        textCursorRects = rows.compactMap { row in
            guard let values = row as? [NSNumber], values.count == 4 else { return nil }
            let rect = NSRect(
                x: values[0].doubleValue,
                y: viewHeight - values[1].doubleValue - values[3].doubleValue,
                width: values[2].doubleValue,
                height: values[3].doubleValue
            )
            return rect.intersection(bounds).isEmpty ? nil : rect.intersection(bounds)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let shortcutModifiers = event.modifierFlags.intersection([
            .command, .control, .option, .shift,
        ])
        guard shortcutModifiers == .command,
              event.charactersIgnoringModifiers?.lowercased() == "c" else {
            return super.performKeyEquivalent(with: event)
        }

        copySelectionToPasteboard()
        return true
    }

    private func copySelectionToPasteboard() {
        Task { @MainActor [weak self] in
            guard let self,
                  let result = try? await evaluateJavaScript(Self.selectionPayloadScript),
                  let payload = result as? [String: Any],
                  let text = payload["text"] as? String,
                  !text.isEmpty else { return }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if let html = payload["html"] as? String, !html.isEmpty {
                pasteboard.setString(html, forType: .html)
            }
        }
    }

    private static let selectionPayloadScript = """
    (() => {
        const selection = window.getSelection();
        if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;

        const container = document.createElement('div');
        for (let i = 0; i < selection.rangeCount; i += 1) {
            container.appendChild(selection.getRangeAt(i).cloneContents());
        }
        container.querySelectorAll('.md-code-copy').forEach((button) => button.remove());
        return { text: selection.toString(), html: container.innerHTML };
    })()
    """

    private static let cursorRectReportingScript = """
    (() => {
        const handler = window.webkit?.messageHandlers?.mdPreviewTextCursorRects;
        if (!handler) return;

        const interactiveSelector = [
            'a', 'button', 'input', 'select', 'textarea', 'summary',
            '[role="button"]', '[contenteditable="true"]', '.md-code-copy'
        ].join(',');
        let scheduledFrame = null;
        let resizeObserver = null;
        let observedArticle = null;

        const schedule = () => {
            if (scheduledFrame !== null) return;
            scheduledFrame = requestAnimationFrame(report);
        };

        const report = () => {
            scheduledFrame = null;
            const article = document.querySelector('article.markdown-body');
            if (!article) {
                handler.postMessage([]);
                return;
            }

            if (observedArticle !== article && window.ResizeObserver) {
                resizeObserver?.disconnect();
                resizeObserver = new ResizeObserver(schedule);
                resizeObserver.observe(article);
                observedArticle = article;
            }

            const viewportWidth = document.documentElement.clientWidth;
            const viewportHeight = document.documentElement.clientHeight;
            const rects = [];
            const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode()) && rects.length < 4096) {
                if (!node.nodeValue || !node.nodeValue.trim()) continue;
                const parent = node.parentElement;
                if (!parent || parent.closest(interactiveSelector)) continue;

                const style = getComputedStyle(parent);
                if (style.display === 'none' || style.visibility === 'hidden'
                    || style.userSelect === 'none') continue;

                const range = document.createRange();
                range.selectNodeContents(node);
                for (const rect of range.getClientRects()) {
                    if (rect.width <= 0 || rect.height <= 0
                        || rect.right <= 0 || rect.bottom <= 0
                        || rect.left >= viewportWidth || rect.top >= viewportHeight) continue;
                    rects.push([rect.left, rect.top, rect.width, rect.height]);
                    if (rects.length >= 4096) break;
                }
            }
            handler.postMessage(rects);
        };

        addEventListener('scroll', schedule, true);
        addEventListener('resize', schedule);
        addEventListener('load', schedule, true);
        document.addEventListener('DOMContentLoaded', schedule, { once: true });
        document.addEventListener('toggle', schedule, true);
        document.fonts?.ready.then(schedule);
        new MutationObserver(schedule).observe(document, {
            subtree: true,
            childList: true,
            characterData: true
        });
        schedule();
    })();
    """

}

final class PreviewViewController: NSViewController, QLPreviewingController {
    private var webView: QuickLookWebView!

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isTextInteractionEnabled = true
        webView = QuickLookWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        view = webView
        preferredContentSize = NSSize(
            width: MarkdownHTML.preferredPageWidth,
            height: MarkdownHTML.preferredPageWidth
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
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
