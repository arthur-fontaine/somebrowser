import Foundation

/// The reader view lives in the page, over it: Readability extracts the article from a copy of the document, and the
/// view is built with DOM calls only (no HTML strings, so pages enforcing Trusted Types work) in a shadow root styled
/// by a constructed stylesheet (which page CSP doesn't restrict).
nonisolated enum ReaderScripts {
    static let hostID = "__browser_reader"

    /// Opens the reader view, or closes it if open. Evaluates to JSON `{open, unavailable?, title?}`.
    static let toggle = """
    (() => {
      const existing = document.getElementById('\(hostID)');
      if (existing) { existing.__close && existing.__close(); return JSON.stringify({ open: false }); }
      \(ReadabilitySource.script)
      const article = new Readability(document.cloneNode(true), { serializer: el => el }).parse();
      if (!article || !article.content || (article.textContent || '').trim().length < 200)
        return JSON.stringify({ open: false, unavailable: true });

      const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text) e.textContent = text; return e; };
      const content = document.importNode(article.content, true);
      // The page's own markup, without handlers or script links.
      for (const node of content.querySelectorAll('*')) {
        for (const attr of [...node.attributes]) {
          if (/^on/i.test(attr.name) || /^\\s*javascript:/i.test(attr.value)) node.removeAttribute(attr.name);
        }
      }

      const host = el('div');
      host.id = '\(hostID)';
      host.style.cssText = 'position:fixed;inset:0;z-index:2147483647;';
      const root = host.attachShadow({ mode: 'open' });
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(\(css));
      root.adoptedStyleSheets = [sheet];

      const scroller = el('div', 'r-scroller');
      const page = el('article', 'r-page');
      const words = (article.textContent || '').trim().split(/\\s+/).length;
      const meta = [article.siteName, article.byline, Math.max(1, Math.round(words / 230)) + ' min read'].filter(Boolean).join(' · ');
      page.append(el('div', 'r-meta', meta), el('h1', 'r-title', article.title || document.title), content);
      const bar = el('div', 'r-bar');
      const smaller = el('button', '', 'A'), larger = el('button', 'r-large', 'A'), close = el('button', 'r-close', '✕');
      smaller.title = 'Smaller text'; larger.title = 'Larger text'; close.title = 'Close Reader (Esc)';
      bar.append(smaller, larger, close);
      scroller.append(page);
      root.append(scroller, bar);

      let size = 20;
      const setSize = s => { size = Math.min(30, Math.max(15, s)); page.style.setProperty('--size', size + 'px'); };
      smaller.onclick = () => setSize(size - 2);
      larger.onclick = () => setSize(size + 2);

      const html = document.documentElement;
      const overflow = html.style.overflow;
      const onKey = e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); host.__close(); } };
      host.__close = () => {
        window.removeEventListener('keydown', onKey, true);
        host.style.opacity = '0';
        setTimeout(() => { host.remove(); html.style.overflow = overflow; }, 180);
      };
      close.onclick = () => host.__close();
      window.addEventListener('keydown', onKey, true);
      html.style.overflow = 'hidden';
      host.style.opacity = '0';
      host.style.transition = 'opacity 180ms ease';
      html.append(host);
      requestAnimationFrame(() => { host.style.opacity = '1'; scroller.classList.add('in'); });
      scroller.tabIndex = -1;
      scroller.focus({ preventScroll: true });
      return JSON.stringify({ open: true, title: article.title || document.title });
    })()
    """

    private static let css: String = {
        let rules = """
        :host { all: initial; color-scheme: light dark; }
        .r-scroller { position: absolute; inset: 0; overflow-y: auto; background: #fbfbf8; color: #1d1d1f; outline: none;
          transform: translateY(14px); transition: transform 320ms cubic-bezier(.2,.9,.25,1); }
        .r-scroller.in { transform: none; }
        .r-page { --size: 20px; box-sizing: border-box; max-width: 720px; margin: 0 auto; padding: 72px 32px 120px;
          font: var(--size)/1.62 ui-serif, "New York", Georgia, serif; }
        .r-meta { font: 13px/1.4 -apple-system, system-ui, sans-serif; color: #6e6e73; margin-bottom: 10px; }
        .r-title { font: 700 2.1em/1.15 -apple-system, system-ui, sans-serif; letter-spacing: -0.02em; margin: 0 0 1.1em; }
        .r-page h1, .r-page h2, .r-page h3, .r-page h4 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.25; margin: 1.6em 0 0.5em; }
        .r-page p, .r-page ul, .r-page ol, .r-page blockquote, .r-page pre, .r-page figure { margin: 0 0 1em; }
        .r-page a { color: #0a64d6; text-decoration: none; }
        .r-page a:hover { text-decoration: underline; }
        .r-page img, .r-page video, .r-page iframe { max-width: 100%; height: auto; border-radius: 8px; }
        .r-page figcaption { font: 13px/1.4 -apple-system, system-ui, sans-serif; color: #6e6e73; margin-top: 6px; }
        .r-page blockquote { border-left: 3px solid #d2d2d7; padding-left: 1em; color: #424245; }
        .r-page pre, .r-page code { font: 0.82em/1.5 ui-monospace, Menlo, monospace; }
        .r-page pre { background: rgba(0,0,0,0.05); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
        .r-page table { border-collapse: collapse; max-width: 100%; display: block; overflow-x: auto; }
        .r-page td, .r-page th { border: 1px solid #d2d2d7; padding: 4px 8px; }
        .r-bar { position: absolute; top: 14px; right: 18px; display: flex; gap: 6px; }
        .r-bar button { all: unset; cursor: default; width: 32px; height: 32px; border-radius: 16px; text-align: center;
          font: 600 13px/32px -apple-system, system-ui, sans-serif; color: inherit; background: rgba(120,120,128,0.14);
          color: #1d1d1f; transition: background 120ms; }
        .r-bar button.r-large { font-size: 17px; }
        .r-bar button:hover { background: rgba(120,120,128,0.24); }
        @media (prefers-color-scheme: dark) {
          .r-scroller { background: #1c1c1e; color: #e5e5e7; }
          .r-meta, .r-page figcaption { color: #98989d; }
          .r-page a { color: #5aa7ff; }
          .r-page blockquote { border-color: #48484a; color: #c7c7cc; }
          .r-page pre { background: rgba(255,255,255,0.07); }
          .r-page td, .r-page th { border-color: #48484a; }
          .r-bar button { color: #e5e5e7; }
        }
        """
        return String(decoding: (try? JSONEncoder().encode(rules)) ?? Data("\"\"".utf8), as: UTF8.self)
    }()
}
