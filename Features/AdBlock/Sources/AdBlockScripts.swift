import Foundation

/// Page side of the ad blocker.
enum AdBlockScripts {
    /// Reports classes and ids (for generic cosmetic rules) as they appear, and creator-support declarations.
    static let observer = """
    (() => {
      if (window.__browserAdblock) return;
      window.__browserAdblock = true;
      const post = (n, b) => window.__browser && window.__browser.post(n, b);
      const seen = new Set();
      let classes = [], ids = [], timer = 0;
      const collect = root => {
        const els = root.querySelectorAll ? [root, ...root.querySelectorAll('[class],[id]')] : [];
        for (const el of els) {
          if (el.id && !seen.has('#' + el.id)) { seen.add('#' + el.id); ids.push(el.id); }
          if (el.classList) for (const c of el.classList) if (!seen.has('.' + c)) { seen.add('.' + c); classes.push(c); }
        }
        if ((classes.length || ids.length) && !timer) timer = setTimeout(flush, 120);
      };
      const flush = () => { timer = 0; post('adblock.classes', { classes, ids }); classes = []; ids = []; };
      collect(document.documentElement);
      new MutationObserver(ms => { for (const m of ms) for (const n of m.addedNodes) if (n.nodeType === 1) collect(n); })
        .observe(document.documentElement, { childList: true, subtree: true });
      if (window === top && document.querySelector('link[rel~="monetization"], meta[name="monetization"]'))
        post('adblock.creator', {});
    })();
    """

    /// Hides `selectors` (one stylesheet per call) and runs the lists' scriptlets.
    static func inject(selectors: [String], script: String) -> String {
        let css = selectors.isEmpty ? "" : selectors.joined(separator: ",\n") + " { display: none !important; }"
        let cssLiteral = String(decoding: (try? JSONSerialization.data(withJSONObject: [css])) ?? Data("[\"\"]".utf8), as: UTF8.self)
        return """
        (() => {
          const css = \(cssLiteral)[0];
          if (css) { const s = document.createElement('style'); s.textContent = css; (document.head || document.documentElement).appendChild(s); }
          \(script.isEmpty ? "" : "try { \(script) } catch (e) {}")
        })();
        """
    }
}
