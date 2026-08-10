# Quick Look Command-C Selection Copy

## Goal

Make Finder Quick Look previews for Markdown copy the currently selected rendered text when the user presses Command-C. Keep the main app's existing copy behavior unchanged and preserve rich HTML plus plain-text clipboard representations.

## Current behavior

The Quick Look extension returns a data-based HTML preview. WebKit paints and selects text correctly, but Finder's Quick Look host does not currently put the selection onto the pasteboard when Command-C is pressed. The page already has a `copy` listener that removes the code-block copy controls from copied fragments.

## Options considered

1. Handle Command-C in the preview HTML and invoke WebKit's native `copy` command. This is the smallest source change, but Finder owns the key equivalent before the data-based HTML preview receives either `keydown` or `keyup`.
2. Show a floating copy button whenever text is selected. This would work around missing keyboard delivery, but it changes the preview UI and does not satisfy the requested shortcut by itself.
3. Replace the data-based Quick Look reply with a view-based extension that owns a `WKWebView` and implements the responder-chain copy action. This puts Command-C handling at the layer where Finder dispatches key equivalents while retaining the same rendered HTML.

## Chosen design

Use option 3. Real Finder testing disproved option 1: both a `keydown` implementation and a `keydown` plus `keyup` implementation left the clipboard unchanged. In the second fixed benchmark, Finder copied the selected Markdown file itself, confirming that its file list remained the responder for Command-C even while the data-based HTML visibly owned a text selection.

The Quick Look extension now owns a `WKWebView`. Its `performKeyEquivalent` handles an unmodified Command-C and asks the page for the current selection. Swift writes both plain text and an HTML fragment to `NSPasteboard`, removing `.md-code-copy` controls from the fragment. The main application remains unchanged because this responder exists only in the extension.

The renderer and appearance resolution are unchanged. Relative local images retain their existing byte budgets and path-safety checks; their existing Quick Look attachments are converted to data URLs for the view-based web view.

## Safety and fallback

- Do not modify the pasteboard without a non-empty active selection.
- Do not intercept modified variants such as Control-Command-C or Option-Command-C.
- Do not change editing, table, code-block button, or main-app behavior.
- Keep the data-based provider source available during local validation so the architecture change is easy to compare and revert before publication.

## Verification

1. Keep the existing renderer and local-image helper regression suites passing.
2. Run the Swift test suite and a full Xcode app build in CI.
3. Side-load the resulting app and Quick Look extension next to the official installation.
4. Put a sentinel value on the pasteboard, select known text in a Markdown Quick Look preview, press Command-C, paste into a text editor, and verify that the selected Markdown text replaced the sentinel.
5. Stop after local installation and verification; create no upstream pull request until the user approves the behavior.
