import Foundation
import JavaScriptCore

/// One site's Boost (Arc): your CSS, your JavaScript and the elements you zapped.
nonisolated struct Boost: Codable, Equatable, Sendable {
    var enabled = true
    var css = ""
    var js = ""
    /// Selectors of zapped elements, hidden on every visit.
    var zapped: [String] = []

    var isEmpty: Bool { css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && zapped.isEmpty }

    /// All the CSS the page gets (zapped elements included).
    var stylesheet: String {
        ([css] + zapped.map { "\($0) { display: none !important; }" }).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The JavaScript's syntax error, if any. A Boost's script shares the page's document-start injection with other
    /// features (ad blocking scriptlets): one that doesn't parse would take them down, so it's checked before saving.
    static func syntaxError(in js: String) -> String? {
        guard !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let context = JSContext() else { return nil }
        var error: String?
        context.exceptionHandler = { _, e in error = e?.toString() }
        _ = context.evaluateScript("(function () {\n" + js + "\n})")
        return error
    }

    /// Runs at document start: the stylesheet right away (constructed, so page CSP doesn't block it, and no flash), the
    /// script once the document is parsed.
    var documentStartScript: String? {
        guard enabled, !isEmpty else { return nil }
        let runsScript = !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Self.syntaxError(in: js) == nil
        return """
        (() => {
          const css = \(Self.literal(stylesheet));
          if (css) {
            const sheet = new CSSStyleSheet();
            sheet.replaceSync(css);
            document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
          }
          \(runsScript ? """
          const run = () => {
            try {
          \(js)
            } catch (e) { console.error('Boost:', e); }
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true }); else run();
          """ : "")
        })();
        """
    }

    static func literal(_ s: String) -> String {
        String(decoding: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}

/// Zap mode: the element under the pointer is outlined; a click hides it and reports a selector for it. Esc ends it.
nonisolated enum ZapScript {
    static let start = """
    (() => {
      if (window.__browserZap) return 'already';
      const box = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #ff3b30;background:rgba(255,59,48,0.12);border-radius:4px;transition:all 80ms ease;display:none;';
      document.documentElement.append(box);
      let target = null;
      const cssEscape = s => (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, '\\\\$&');
      const selector = el => {
        const parts = [];
        for (let e = el; e && e.nodeType === 1 && e !== document.documentElement; e = e.parentElement) {
          if (e.id) { parts.unshift('#' + cssEscape(e.id)); break; }
          let part = e.localName;
          const classes = [...e.classList].filter(c => !/\\d{3,}/.test(c)).slice(0, 2);
          if (classes.length) part += '.' + classes.map(cssEscape).join('.');
          const siblings = e.parentElement ? [...e.parentElement.children].filter(s => s.localName === e.localName) : [];
          if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(e) + 1) + ')';
          parts.unshift(part);
        }
        return parts.join(' > ');
      };
      const move = e => {
        target = e.target;
        const r = target.getBoundingClientRect();
        Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
      };
      const click = e => {
        e.preventDefault(); e.stopPropagation();
        if (!target || target === document.body) return;
        const s = selector(target);
        target.style.setProperty('display', 'none', 'important');
        box.style.display = 'none';
        window.__browser && window.__browser.post('boosts.zap', { selector: s });
      };
      const stop = () => {
        removeEventListener('mousemove', move, true); removeEventListener('click', click, true); removeEventListener('keydown', key, true);
        box.remove(); delete window.__browserZap;
        window.__browser && window.__browser.post('boosts.zap-end', {});
      };
      const key = e => { if (e.key === 'Escape') { e.preventDefault(); stop(); } };
      addEventListener('mousemove', move, true); addEventListener('click', click, true); addEventListener('keydown', key, true);
      window.__browserZap = stop;
      return 'zapping';
    })()
    """

    static let stop = "window.__browserZap && window.__browserZap()"
}
