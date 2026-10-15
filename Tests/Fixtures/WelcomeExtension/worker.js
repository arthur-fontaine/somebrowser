chrome.runtime.onInstalled.addListener(async () => {
  try { await chrome.tabs.create({ url: 'welcome.html' }); await chrome.storage.local.set({ welcome: 'ok' }); }
  catch (e) { await chrome.storage.local.set({ welcome: 'error: ' + e.message }); }
});
