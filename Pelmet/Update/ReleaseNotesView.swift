// ReleaseNotesView.swift
// The release-notes snippet (scripts/release-notes-html.py) in a web view:
// the same HTML and stylesheet Sparkle's update window shows, so About's
// "What's new" and the update window read as one. Links open the browser.

import AppKit
import SwiftUI
import WebKit

enum ReleaseNotesNavigation {
    enum Decision: Equatable {
        case allow
        case open(URL)
        case cancel
    }

    static func decide(url: URL?, type: WKNavigationType, mainFrame: Bool) -> Decision {
        guard let url else { return .cancel }
        if type == .linkActivated, url.scheme?.lowercased() == "https",
           let host = url.host, !host.isEmpty, url.user == nil, url.password == nil {
            return .open(url)
        }
        return type == .other && mainFrame && url.absoluteString == "about:blank" ? .allow : .cancel
    }

    static func document(_ html: String) -> String {
        """
        <!DOCTYPE html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'"></head>
        \(html)
        """
    }
}

struct ReleaseNotesView: View {
    let title: String
    let html: String
    /// Fixed width: the snippet is laid out at this width before it is
    /// measured, so the popover fits its notes instead of a guess.
    static let width: CGFloat = 380
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Link("All releases ↗", destination: URL(string: "https://github.com/fif7y/dimble/releases")!)
                    .font(.caption)
                    .foregroundStyle(PelmetAccent.accent)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            NotesWebView(html: html, width: Self.width, contentHeight: $contentHeight)
                .frame(height: min(max(contentHeight, 60), 340))
        }
        .frame(width: Self.width)
    }
}

private struct NotesWebView: NSViewRepresentable {
    let html: String
    let width: CGFloat
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(contentHeight: $contentHeight) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The notes are static; only our own height probe runs.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 120), configuration: config)
        // Transparent, so the snippet sits on the popover's own material.
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        // The snippet has no DOCTYPE (Sparkle embeds it in its own page). In
        // quirks mode the root stretches to the viewport, so short notes
        // measured 120 and kept a blank popover.
        view.loadHTMLString(ReleaseNotesNavigation.document(html), baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let contentHeight: Binding<CGFloat>

        init(contentHeight: Binding<CGFloat>) { self.contentHeight = contentHeight }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            switch ReleaseNotesNavigation.decide(
                url: navigationAction.request.url, type: navigationAction.navigationType,
                mainFrame: navigationAction.targetFrame?.isMainFrame == true
            ) {
            case .allow: return .allow
            case .open(let url):
                NSWorkspace.shared.open(url)
                return .cancel
            case .cancel: return .cancel
            }
        }

        /// The body's own box, which (unlike the root's scroll height) can
        /// come out shorter than the view it's laid out in.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task {
                if let height = try? await webView.evaluateJavaScript("Math.ceil(document.body.getBoundingClientRect().height)") as? Double {
                    contentHeight.wrappedValue = height
                }
            }
        }
    }
}
