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
  // What Claude in Chrome does for a session (docs/decisions/0005): a background tab in the last focused normal
  // window, grouped in its own window, the group renamed; then each new tab of the session (its tabs_create_mcp) opens
  // in the group's window and joins the group. The ids must last, and the group hold both tabs.
  async claude(sender) {
    try {
      const url = new URL('/two', sender.tab.url).href;
      const win = await chrome.windows.getLastFocused({ windowTypes: ['normal'] });
      const tab = await chrome.tabs.create({ windowId: win.id, url, active: false });
      await wait(1000);
      const again = await chrome.tabs.get(tab.id);
      const group = await chrome.tabs.group({ tabIds: [tab.id], createProperties: { windowId: again.windowId } });
      await chrome.tabGroups.update(group, { title: 'Claude', color: 'orange' });
      const { windowId } = await chrome.tabGroups.get(group);
      const second = await chrome.tabs.create({ windowId, url, active: false });
      await wait(1000);
      await chrome.tabs.group({ tabIds: second.id, groupId: group });
      const members = (await chrome.tabs.query({ groupId: group })).map(t => t.id).sort();
      if (JSON.stringify(members) !== JSON.stringify([tab.id, second.id].sort())) return 'members ' + JSON.stringify(members);
      const listed = (await chrome.tabGroups.query({})).filter(g => g.id === group);
      if (listed.length !== 1 || listed[0].title !== 'Claude') return 'groups ' + JSON.stringify(listed);
      return 'ok';
    } catch (e) { return err(e); }
  },
  // Its fallback when no window is normal: a new window, whose tab must last too.
  async window(sender) {
    try {
      const created = await chrome.windows.create({ url: new URL('/three', sender.tab.url).href, type: 'normal', focused: false });
      await wait(1000);
      const tab = await chrome.tabs.get(created.tabs[0].id);
      return tab.windowId === created.id ? 'ok' : 'moved to ' + tab.windowId;
    } catch (e) { return err(e); }
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
  // The Origin the server sees for the worker's fetches (the test server echoes it).
  async origin(sender) {
    const echo = new URL('/echo', sender.tab.url).href;
    try {
      const get = await (await fetch(echo)).text();
      const post = await (await fetch(echo, { method: 'POST', body: 'x' })).text();
      return { get, post, self: location.origin };
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
