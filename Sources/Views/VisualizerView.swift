import SwiftUI
import WebKit
import AppKit

/// "Visualize" tab: shows the page produced by `pm.visualizer.set(template, data)` (the Handlebars template is already rendered by runner.js).
/// The page gets a small `pm` shim: `pm.getData(cb)` returns the data, and `document.execCommand('copy')` writes to the system clipboard
/// (WKWebView refuses it without a user gesture, so the auto-copy in templates would silently do nothing).
struct VisualizerView: NSViewRepresentable {
    let html: String
    let dataJSON: String

    final class Coord: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var loaded = ""
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let d = m.body as? [String: Any], let t = d["copy"] as? String else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
        }
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if a.navigationType == .linkActivated, let u = a.request.url {      // links open in the default browser, never inside the tab
                if ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(u) }
                decisionHandler(.cancel); return
            }
            decisionHandler(a.targetFrame == nil ? .cancel : .allow)
        }
        func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = a.request.url, ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(u) }
            return nil                                                          // target=_blank: no new windows
        }
    }
    func makeCoordinator() -> Coord { Coord() }

    private static let shim = """
    (function () {
      var DATA = __DATA__;
      window.pm = { getData: function (cb) { setTimeout(function () { cb(null, DATA); }, 0); }, onEvent: function () {} };
      var orig = document.execCommand ? document.execCommand.bind(document) : null;
      document.execCommand = function (cmd) {
        if (String(cmd).toLowerCase() === 'copy') {
          var el = document.activeElement, t = '';
          if (el && (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') && el.selectionStart != null) t = el.value.substring(el.selectionStart, el.selectionEnd);
          if (!t) t = String(window.getSelection ? window.getSelection() : '');
          window.webkit.messageHandlers.pw.postMessage({ copy: t });
          return true;
        }
        return orig ? orig.apply(null, arguments) : false;
      };
    })();
    """

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "pw")
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = context.coordinator; w.uiDelegate = context.coordinator
        return w
    }
    static func dismantleNSView(_ w: WKWebView, coordinator: Coord) {
        w.configuration.userContentController.removeAllScriptMessageHandlers()
        w.configuration.userContentController.removeAllUserScripts()
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        let key = dataJSON + "\u{0}" + html
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        let ucc = w.configuration.userContentController
        ucc.removeAllUserScripts()
        let data = dataJSON.isEmpty ? "null" : dataJSON
        ucc.addUserScript(WKUserScript(source: Self.shim.replacingOccurrences(of: "__DATA__", with: data),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let page = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light">
        <style>html,body{background:#fff;color:#1c1c1e;font:13px -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;margin:12px}
        a{color:#0a64d8}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px}</style></head><body>\(html)</body></html>
        """
        w.loadHTMLString(page, baseURL: nil)
    }
}

/// Visualize tab content: the page, or the reason why there is none.
struct VisualizePane: View {
    let html: String
    let data: String
    let error: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !error.isEmpty {
                Label(L("Visualizer: %@", error), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
            VisualizerView(html: html, dataJSON: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        }
    }
}
