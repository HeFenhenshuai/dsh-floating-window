// The bridge between the native window and the page.
//
// The page was written for WebView2, where the native half is reachable through
// `window.chrome.webview` (`postMessage` to the window, `addEventListener`
// ('message') from it). WKWebView has no such object, so the window injects a
// shim that implements exactly that surface on top of `webkit.messageHandlers`
// — the page itself stays unchanged.
//
// The same document-start script does three more things:
//
//  * `window.__DSH_FLOAT_NATIVE__ = true`, so the page hides its own browser
//    chrome and lets this window own it;
//  * a top inset, so the page's first row starts below the native title bar
//    instead of underneath the traffic lights;
//  * when the Desktop shell handed us its renderer capability header, every
//    request the page makes carries it — WKWebView has no request-interception
//    API, so the page's `fetch`/`EventSource` are wrapped instead (a plain
//    EventSource cannot send headers at all, hence the streaming shim).

import Foundation
import WebKit

enum Bridge {
    static let handlerName = "dshFloat"

    static func userScript(options: LaunchOptions, topInset: CGFloat) -> WKUserScript {
        let inset = max(0, Int(topInset.rounded()))
        let headerName = options.headerName ?? ""
        let headerValue = options.headerValue ?? ""
        let hasHeader = !headerName.isEmpty && !headerValue.isEmpty
        let script = """
        (function () {
          if (window.__DSH_FLOAT_NATIVE__ === true) return;
          window.__DSH_FLOAT_NATIVE__ = true;

          /* ── message channel (the WebView2 surface) ───────────────────── */
          var listeners = [];
          window.__DSH_FLOAT_NATIVE_ONMESSAGE__ = function (data) {
            for (var i = 0; i < listeners.length; i += 1) {
              try { listeners[i]({ data: data }); } catch (error) { /* page handler */ }
            }
          };
          var post = function (message) {
            try { window.webkit.messageHandlers.\(handlerName).postMessage(message); } catch (error) { /* no host */ }
          };
          window.chrome = window.chrome || {};
          window.chrome.webview = {
            postMessage: post,
            addEventListener: function (type, callback) {
              if (type === 'message' && typeof callback === 'function') listeners.push(callback);
            },
            removeEventListener: function (type, callback) {
              var index = listeners.indexOf(callback);
              if (index >= 0) listeners.splice(index, 1);
            }
          };

          /* ── keep the page clear of the native title bar ──────────────── */
          var style = document.createElement('style');
          style.setAttribute('data-dsh-float', 'native-inset');
          style.textContent = 'body { padding-top: \(inset)px !important; }';
          (document.head || document.documentElement).appendChild(style);

          \(hasHeader ? headerScript(name: headerName, value: headerValue) : "")
        })();
        """
        return WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Attach the renderer capability header to everything the page asks for.
    private static func headerScript(name: String, value: String) -> String {
        let header = "{\"\(name.dshJSString)\": \"\(value.dshJSString)\"}"
        return """
          /* ── renderer capability header on every page request ─────────── */
          var DSH_HEADER = \(header);
          var applyHeader = function (init) {
            var next = init || {};
            var headers = {};
            var source = next.headers;
            if (source instanceof Headers) { source.forEach(function (v, k) { headers[k] = v; }); }
            else if (Array.isArray(source)) { source.forEach(function (pair) { headers[pair[0]] = pair[1]; }); }
            else if (source && typeof source === 'object') {
              Object.keys(source).forEach(function (key) { headers[key] = source[key]; });
            }
            headers['\(name.dshJSString)'] = '\(value.dshJSString)';
            next.headers = headers;
            return next;
          };
          if (typeof window.fetch === 'function') {
            var nativeFetch = window.fetch;
            window.fetch = function (input, init) {
              try {
                if (typeof input === 'string' || (typeof URL !== 'undefined' && input instanceof URL)) {
                  return nativeFetch.call(this, input, applyHeader(init));
                }
                if (typeof Request !== 'undefined' && input instanceof Request) {
                  var patched = applyHeader(init);
                  return nativeFetch.call(this, new Request(input, patched));
                }
              } catch (error) { /* fall through to the untouched call */ }
              return nativeFetch.call(this, input, init);
            };
          }
          /* A plain EventSource cannot carry headers: stream it with fetch. */
          var HeaderEventSource = function (url) {
            var self = this;
            this.url = String(url);
            this.readyState = 0;
            this.onopen = null;
            this.onmessage = null;
            this.onerror = null;
            this._abort = new AbortController();
            var headers = {};
            headers['\(name.dshJSString)'] = '\(value.dshJSString)';
            fetch(this.url, { headers: headers, cache: 'no-store', signal: this._abort.signal })
              .then(function (response) {
                if (!response.ok || !response.body) throw new Error('HTTP ' + response.status);
                self.readyState = 1;
                if (typeof self.onopen === 'function') self.onopen({ type: 'open' });
                var reader = response.body.getReader();
                var decoder = new TextDecoder();
                var buffer = '';
                var pump = function () {
                  return reader.read().then(function (step) {
                    if (step.done) {
                      self.readyState = 2;
                      if (typeof self.onerror === 'function') self.onerror({ type: 'error' });
                      return;
                    }
                    buffer += decoder.decode(step.value, { stream: true });
                    var index = buffer.indexOf('\\n\\n');
                    while (index >= 0) {
                      var chunk = buffer.slice(0, index);
                      buffer = buffer.slice(index + 2);
                      emit(chunk);
                      index = buffer.indexOf('\\n\\n');
                    }
                    return pump();
                  });
                };
                var emit = function (chunk) {
                  var data = [];
                  var lines = chunk.split('\\n');
                  for (var i = 0; i < lines.length; i += 1) {
                    var line = lines[i];
                    if (line.indexOf('data:') === 0) data.push(line.slice(5).replace(/^ /, ''));
                  }
                  if (data.length === 0) return;
                  if (typeof self.onmessage === 'function') self.onmessage({ type: 'message', data: data.join('\\n') });
                };
                return pump();
              })
              .catch(function () {
                if (self.readyState === 2) return;
                self.readyState = 2;
                if (typeof self.onerror === 'function') self.onerror({ type: 'error' });
              });
          };
          HeaderEventSource.prototype.close = function () {
            this.readyState = 2;
            try { this._abort.abort(); } catch (error) { /* already closed */ }
          };
          if (typeof window.EventSource === 'function') window.EventSource = HeaderEventSource;
        """
    }
}

extension String {
    /// Escape a value for use inside a single-quoted or double-quoted JS string.
    var dshJSString: String {
        var out = ""
        for character in self {
            switch character {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        return out
    }
}
