const wait = ms => new Promise(r => setTimeout(r, ms));
const err = e => 'error: ' + (e && e.message || e);
const probes = {
  async tabs(sender) {
    const created = await chrome.tabs.create({ url: new URL('/two', sender.tab.url).href });
    let status = null;
    for (let i = 0; i < 40; i++) {
      try { status = (await chrome.tabs.get(created.id)).status; if (status === 'complete') break; } catch (e) { status = err(e); break; }
      await wait(250);
    }
    return { created: created.id, status, urls: (await chrome.tabs.query({})).map(t => t.url) };
  },
  async remove() {
    const tabs = (await chrome.tabs.query({})).filter(t => new URL(t.url).pathname === '/two');
    try { await chrome.tabs.remove(tabs.map(t => t.id)); return 'removed ' + tabs.length; } catch (e) { return err(e); }
  },
  async update(sender) {
    try { return 'ok ' + (await chrome.tabs.update(sender.tab.id, { url: new URL('/three', sender.tab.url).href })).id; } catch (e) { return err(e); }
  },
  async script(sender) {
    try { const [r] = await chrome.scripting.executeScript({ target: { tabId: sender.tab.id }, func: () => document.title }); return r.result; } catch (e) { return err(e); }
  },
  async offscreen() {
    try {
      await chrome.offscreen.createDocument({ url: 'offscreen.html', reasons: ['DOM_PARSER'], justification: 'probe' });
      return await chrome.runtime.sendMessage({ target: 'offscreen', html: '<p>hi</p>' });
    } catch (e) { return err(e); }
  },
  async auth(sender) {
    const url = new URL('/auth?n=' + Date.now() + '&to=' + encodeURIComponent(chrome.identity.getRedirectURL('cb')), sender.tab.url).href;
    try { return await chrome.identity.launchWebAuthFlow({ url, interactive: true }); } catch (e) { return err(e); }
  },
};
chrome.runtime.onMessage.addListener((m, sender, reply) => {
  if (typeof m !== 'string' || !probes[m]) return;
  probes[m](sender).then(reply, e => reply(err(e)));
  return true;
});
let commands = 0;
chrome.commands.onCommand.addListener(c => chrome.storage.local.set({ command: c + ':' + (++commands) }));
chrome.runtime.onInstalled.addListener(() => chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }));
