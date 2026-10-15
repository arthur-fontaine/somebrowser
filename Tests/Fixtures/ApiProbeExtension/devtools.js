chrome.devtools.panels.create('Probe', '', 'panel.html', () => chrome.storage.local.set({ devtools: 'panel created' }));
