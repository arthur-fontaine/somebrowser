chrome.runtime.onMessage.addListener((m, s, reply) => {
  if (!m || m.target !== 'offscreen') return;
  reply('parsed:' + new DOMParser().parseFromString(m.html, 'text/html').querySelector('p').textContent);
});
