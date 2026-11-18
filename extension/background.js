// Task Board tab reuse.
//
// When "Switch to a tab that is already open" is on, Task Board opens links with the marker below
// on the end. A browser always puts an outside link in a new tab, so this extension watches for
// that new tab: if another tab already shows the page, it switches to that one and closes the new
// one. Links without the marker are never touched.

const MARKER = "taskboard-reuse";

/** The real address behind a marked one, or null for an ordinary address. */
function unmark(address) {
  let url;
  try {
    url = new URL(address);
  } catch {
    return null;
  }
  if (url.hash !== "#" + MARKER) return null;
  url.hash = "";
  return url;
}

function trimmedPath(url) {
  return url.pathname.replace(/\/+$/, "");
}

/**
 * How well a tab matches the page being opened: 2 for the same page, 1 for a page beneath it
 * (a pull request's Files tab is still that pull request), 0 for anything else.
 */
function matchQuality(tabAddress, target) {
  let url;
  try {
    url = new URL(tabAddress);
  } catch {
    return 0;
  }
  if (url.origin !== target.origin) return 0;
  // A query that names the page has to match. Without one, the tab's own query is ignored.
  if (target.search && url.search !== target.search) return 0;
  const want = trimmedPath(target);
  const have = trimmedPath(url);
  if (have === want) return 2;
  // The site's front page is not "above" every other page on it.
  if (want !== "" && have.startsWith(want + "/")) return 1;
  return 0;
}

// A new tab is reported twice, on creation and when its address is set. Act once.
const handled = new Set();

async function reuseTab(newTab, address) {
  const target = unmark(address);
  if (!target || handled.has(newTab.id)) return;
  handled.add(newTab.id);

  try {
    const tabs = await chrome.tabs.query({});
    const existing = tabs
      .filter((tab) => tab.id !== newTab.id)
      .map((tab) => ({ tab, quality: matchQuality(tab.url || tab.pendingUrl || "", target) }))
      .filter((candidate) => candidate.quality > 0)
      // Best match first, then the one used most recently.
      .sort((a, b) => b.quality - a.quality || (b.tab.lastAccessed || 0) - (a.tab.lastAccessed || 0))[0];

    if (existing) {
      await chrome.tabs.update(existing.tab.id, { active: true });
      await chrome.windows.update(existing.tab.windowId, { focused: true });
      await chrome.tabs.remove(newTab.id);
    } else {
      // Nothing to reuse: keep the new tab, with the marker taken off its address.
      await chrome.tabs.update(newTab.id, { url: target.href });
    }
  } catch (error) {
    console.warn("Task Board tab reuse:", error);
  } finally {
    setTimeout(() => handled.delete(newTab.id), 5000);
  }
}

chrome.tabs.onCreated.addListener((tab) => {
  reuseTab(tab, tab.pendingUrl || tab.url || "");
});

chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (change.url) reuseTab(tab, change.url);
});
