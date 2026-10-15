// Results go through storage, so every page shows them (a probe may change the selected tab).
chrome.runtime.onMessage.addListener((m, s, reply) => { if (m === 'ping') reply('pong:' + location.pathname); });
const show = items => { for (const [k, v] of Object.entries(items)) document.documentElement.dataset[k] = typeof v === 'string' ? v : JSON.stringify(v); };
chrome.storage.local.get(null, show);
chrome.storage.onChanged.addListener(changes => show(Object.fromEntries(Object.entries(changes).map(([k, c]) => [k, c.newValue]))));
window.addEventListener('message', e => {
  if (!e.data || !e.data.probe) return;
  chrome.runtime.sendMessage(e.data.probe, r => chrome.storage.local.set({ ['r_' + e.data.probe]: JSON.stringify(r ?? chrome.runtime.lastError?.message ?? null) }));
});
document.documentElement.dataset.probe = 'ready';
