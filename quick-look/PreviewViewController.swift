//
//  PreviewViewController.swift
//  quick-look
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import Quartz
import WebKit

private final class QuickLookWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }

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

    static let textCursorStyleScript = """
    (() => {
        if (document.getElementById('md-quick-look-interaction')) return;

        const style = document.createElement('style');
        style.id = 'md-quick-look-interaction';
        style.textContent = `
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
        `;
        (document.head || document.documentElement).appendChild(style);
    })()
    """
}

final class PreviewViewController: NSViewController, QLPreviewingController {
    private var webView: QuickLookWebView!

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isTextInteractionEnabled = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: QuickLookWebView.textCursorStyleScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
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
