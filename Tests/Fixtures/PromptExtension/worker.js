// Each click of its action asks for one of Chrome's prompts, in turn: a permission, then removing itself. Asked for at
// once in the click's listener (Chrome needs the click's user gesture); the answer shows in its badge.
let clicks = 0;
const badge = text => chrome.action.setBadgeText({ text });
chrome.action.onClicked.addListener(() => {
  if (clicks++ % 2 === 0) {
    chrome.permissions.request({ permissions: ['bookmarks'] }).then(granted => badge(granted ? 'Y' : 'N'), () => badge('E'));
  } else {
    chrome.management.uninstallSelf({ showConfirmDialog: true }).catch(() => badge('K'));
  }
});
