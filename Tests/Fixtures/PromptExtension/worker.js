// Its action asks for Chrome's prompts in turn: a permission, then (once answered) removing itself. Asked for at once
// in the click's listener (Chrome needs the click's user gesture); clicks while a prompt is up are ignored. The answer
// shows in its badge.
let step = 'permission';
let asking = false;
const badge = text => chrome.action.setBadgeText({ text });
chrome.action.onClicked.addListener(() => {
  if (asking) return;
  asking = true;
  if (step === 'permission') {
    chrome.permissions.request({ permissions: ['bookmarks'] })
      .then(granted => badge(granted ? 'Y' : 'N'), () => badge('E'))
      .finally(() => { step = 'remove'; asking = false; });
  } else {
    chrome.management.uninstallSelf({ showConfirmDialog: true }).catch(() => badge('K')).finally(() => { asking = false; });
  }
});
