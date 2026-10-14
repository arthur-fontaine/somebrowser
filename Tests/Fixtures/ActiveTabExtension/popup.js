// No host permissions: executeScript only succeeds when the action invocation granted activeTab.
(async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: () => { document.title = 'granted'; } });
  document.body.textContent = 'granted';
})().catch(e => { document.body.textContent = 'error: ' + e.message; });
