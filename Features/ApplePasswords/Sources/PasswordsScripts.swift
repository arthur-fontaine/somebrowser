import Foundation

/// Page side of Apple Passwords: field detection, keyboard forwarding, submit capture, filling.
enum PasswordsScripts {
    /// Shared helpers (both scripts run them: the observer in its world, fills in the page's).
    static let common = """
    const pwVisible = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const pwIsPassword = el => el instanceof HTMLInputElement && el.type === 'password';
    const pwIsText = el => el instanceof HTMLInputElement && ['text', 'email', 'tel', ''].includes(el.type);
    const pwRoot = el => el.form || el.closest('form') || document;
    const pwFields = root => [...root.querySelectorAll('input[type=password]')].filter(pwVisible);
    const pwIsNew = fields => fields.length >= 2 || fields.some(p => /new-password/.test(p.autocomplete || ''));
    const pwUsername = (root, password) => {
      const tagged = root.querySelector('input[autocomplete~="username"], input[autocomplete~="email"]');
      if (tagged && pwVisible(tagged)) return tagged;
      const inputs = [...root.querySelectorAll('input')].filter(i => pwVisible(i) && (pwIsText(i) || pwIsPassword(i)));
      const end = password ? inputs.indexOf(password) : inputs.length;
      for (let i = (end < 0 ? inputs.length : end) - 1; i >= 0; i--) if (pwIsText(inputs[i])) return inputs[i];
      return null;
    };
    """

    /// Observer, injected at document end in the main frame.
    static let observer = """
    (() => {
      if (window.__browserPasswordsObserver) return;
      window.__browserPasswordsObserver = true;
      \(common)
      const post = (n, b) => window.__browser && window.__browser.post(n, b);
      const menuOpen = () => document.documentElement.dataset.browserPwMenu === '1';
      const classify = el => {
        if (!(el instanceof HTMLInputElement) || el.readOnly || el.disabled) return null;
        const root = pwRoot(el), fields = pwFields(root);
        if (!fields.length) return pwIsText(el) && /\\b(username|email)\\b/.test(el.autocomplete || '') ? 'login' : null;
        if (pwIsPassword(el)) return pwIsNew(fields) && !/current-password/.test(el.autocomplete || '') ? 'new' : 'login';
        return pwUsername(root, fields[0]) === el ? (pwIsNew(fields) ? 'new' : 'login') : null;
      };
      let current = null;
      document.addEventListener('focusin', e => {
        const kind = classify(e.target);
        if (!kind) return;
        current = e.target;
        document.querySelectorAll('[data-browser-pw]').forEach(x => x.removeAttribute('data-browser-pw'));
        current.setAttribute('data-browser-pw', '');
        const r = current.getBoundingClientRect();
        post('passwords.focus', { kind, rect: { x: r.left, y: r.top, width: r.width, height: r.height } });
      }, true);
      document.addEventListener('focusout', e => {
        if (e.target === current) { current = null; post('passwords.blur', {}); }
      }, true);
      let lastCapture = 0;
      const capture = root => {
        const filled = pwFields(root).filter(p => p.value);
        if (!filled.length || Date.now() - lastCapture < 1000) return;
        lastCapture = Date.now();
        const isNew = pwIsNew(filled);
        const user = pwUsername(root, filled[0]);
        post('passwords.submit', { isNew, username: user ? user.value : '', password: filled[filled.length - 1].value });
      };
      document.addEventListener('keydown', e => {
        if (menuOpen() && e.target === current && ['ArrowDown', 'ArrowUp', 'Enter', 'Escape'].includes(e.key)) {
          e.preventDefault(); e.stopImmediatePropagation();
          post('passwords.key', { key: e.key });
        } else if (e.key === 'Enter' && pwIsPassword(e.target)) {
          capture(pwRoot(e.target));
        }
      }, true);
      document.addEventListener('submit', e => capture(e.target), true);
      document.addEventListener('click', e => {
        const b = e.target.closest && e.target.closest('button, input[type=submit]');
        if (b && (b.type === 'submit' || b.form)) capture(pwRoot(b));
      }, true);
    })();
    """

    /// Tells the page whether our dropdown is open (it then forwards arrow keys, Enter and Escape).
    static func menu(open: Bool) -> String {
        open ? "document.documentElement.dataset.browserPwMenu = '1';" : "delete document.documentElement.dataset.browserPwMenu;"
    }

    /// Fills the focused field's form: a login (username + password) or a new password (password and confirmation).
    static func fill(username: String?, password: String, newPassword: Bool) -> String {
        let user = username.map(literal) ?? "null"
        return """
        (() => {
          \(common)
          const target = document.querySelector('[data-browser-pw]');
          if (!target) return false;
          const root = pwRoot(target), fields = pwFields(root);
          const set = (el, v) => {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const user = \(user);
          if (\(newPassword)) {
            fields.filter(p => !/current-password/.test(p.autocomplete || '')).forEach(p => set(p, \(literal(password))));
          } else {
            const password = pwIsPassword(target) ? target : fields[0];
            if (user !== null) { const u = pwUsername(root, password) || (pwIsText(target) ? target : null); if (u) set(u, user); }
            if (password) set(password, \(literal(password)));
          }
          return true;
        })()
        """
    }

    /// A JavaScript string literal (JSON-escaped).
    static func literal(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8), as: UTF8.self)
            .dropFirst().dropLast().description
    }
}
