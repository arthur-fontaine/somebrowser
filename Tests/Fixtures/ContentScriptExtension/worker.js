chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message !== 'hello') return;
  // Storage too, so the worker's extension APIs are exercised, not just messaging.
  chrome.storage.local.set({ seen: sender.tab ? sender.tab.url : 'unknown' }, () => reply('worker:' + chrome.runtime.id.length));
  return true;
});
