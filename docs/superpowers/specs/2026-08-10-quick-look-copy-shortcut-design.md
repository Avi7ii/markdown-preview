# Quick Look Command-C Selection Copy

## Goal

Make Finder Quick Look previews for Markdown copy the currently selected rendered text when the user presses Command-C. Keep the main app's existing copy behavior unchanged and preserve rich HTML plus plain-text clipboard representations.

## Current behavior

The Quick Look extension returns a data-based HTML preview. WebKit paints and selects text correctly, but Finder's Quick Look host does not currently put the selection onto the pasteboard when Command-C is pressed. The page already has a `copy` listener that removes the code-block copy controls from copied fragments.

## Options considered

1. Handle Command-C in the preview HTML and invoke WebKit's native `copy` command. This is the smallest change, reuses the existing `copy` event sanitizer, and retains formatted and plain-text clipboard data.
2. Show a floating copy button whenever text is selected. This would work around missing keyboard delivery, but it changes the preview UI and does not satisfy the requested shortcut by itself.
3. Replace the data-based Quick Look reply with a view-based extension that owns a `WKWebView` and implements the responder-chain copy action. This provides full native control but substantially rewrites the extension architecture and raises regression risk.

## Chosen design

Use option 1 first. In read-only HTML previews only, a capture-phase `keydown` handler recognizes unmodified Command-C, requires a non-collapsed selection, and calls `document.execCommand('copy')`. It prevents the key event only when WebKit reports that copying succeeded. The main application is excluded through the existing host-bridge check, so its native responder path is untouched.

The existing `copy` listener remains the single place that sanitizes copied selection markup. Normal selections retain WebKit's native rich/plain clipboard representations; selections spanning code blocks continue to omit `.md-code-copy` buttons.

## Safety and fallback

- Do not intercept Command-C without an active selection.
- Do not intercept modified variants such as Control-Command-C or Option-Command-C.
- Do not intercept during IME composition.
- Do not change editing, table, code-block button, or main-app behavior.
- If real Finder testing proves that Quick Look never delivers the key event to the HTML document, instrument event delivery before considering option 2 or the view-based rewrite.

## Verification

1. Add render-level regression tests for the read-only shortcut guard and copy invocation.
2. Run the Swift test suite and a full Xcode app build in CI.
3. Side-load the resulting app and Quick Look extension next to the official installation.
4. Put a sentinel value on the pasteboard, select known text in a Markdown Quick Look preview, press Command-C, paste into a text editor, and verify that the selected Markdown text replaced the sentinel.
5. Stop after local installation and verification; create no upstream pull request until the user approves the behavior.
