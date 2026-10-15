chrome.runtime.sendMessage('hello', answer => { document.documentElement.dataset.extension = answer || 'no answer'; });
