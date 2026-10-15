// A badge for every tab, and (once) a download started by no page: both reach the browser.
chrome.action.setBadgeText({ text: '7' });
chrome.runtime.onInstalled.addListener(() => {
  setTimeout(() => chrome.downloads.download({ url: 'data:text/plain;base64,aGVsbG8=', filename: 'badge-extension.txt' }), 3000);
});
