import Foundation
import Testing
import WebKit
@testable import Pelmet

@MainActor
struct ReleaseNotesNavigationTests {
    @Test func onlyUserActivatedHTTPSLinksOpenExternally() throws {
        let url = try #require(URL(string: "https://github.com/fif7y/dimble/releases"))
        #expect(ReleaseNotesNavigation.decide(url: url, type: .linkActivated, mainFrame: true) == .open(url))
        #expect(ReleaseNotesNavigation.decide(url: url, type: .other, mainFrame: true) == .cancel)
        #expect(ReleaseNotesNavigation.decide(url: url, type: .formSubmitted, mainFrame: true) == .cancel)
    }

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello",
        "http://example.com", "some-app://command", "https://user:password@example.com"
    ])
    func blocksUnsafeLinks(value: String) throws {
        let url = try #require(URL(string: value))
        #expect(ReleaseNotesNavigation.decide(url: url, type: .linkActivated, mainFrame: true) == .cancel)
    }

    @Test func allowsInitialDocumentButNotFrameNavigation() throws {
        let url = try #require(URL(string: "about:blank"))
        #expect(ReleaseNotesNavigation.decide(url: url, type: .other, mainFrame: true) == .allow)
        #expect(ReleaseNotesNavigation.decide(url: url, type: .other, mainFrame: false) == .cancel)
        #expect(ReleaseNotesNavigation.decide(url: nil, type: .other, mainFrame: true) == .cancel)
    }

    @Test func documentBlocksScriptsAndSubresourcesButPreservesNotes() async throws {
        let probe = ResourceProbe()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(probe, forURLScheme: "probe")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString(ReleaseNotesNavigation.document("""
            <style>#notes { color: rgb(0, 128, 0); }</style>
            <p id="notes">Release notes</p>
            <script>document.getElementById('notes').textContent = 'injected';</script>
            <img src="probe://external/image">
            """), baseURL: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while view.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!view.isLoading)
        let text = try await view.evaluateJavaScript("document.getElementById('notes').textContent") as? String
        let color = try await view.evaluateJavaScript("getComputedStyle(document.getElementById('notes')).color") as? String
        #expect(text == "Release notes")
        #expect(color == "rgb(0, 128, 0)")
        #expect(probe.requests == 0)
    }

    private final class ResourceProbe: NSObject, WKURLSchemeHandler {
        var requests = 0

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            requests += 1
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    }
}
