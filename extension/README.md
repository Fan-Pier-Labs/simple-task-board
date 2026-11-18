# Task Board tab reuse

A small browser extension for Chrome and other Chromium browsers (Edge, Brave, Arc).

A browser always opens a link from another app in a new tab. With this extension, when Task Board
opens a pull request or a Jira issue that is already open in a tab, the browser switches to that
tab instead, and the new tab is closed. A pull request's Files or Checks page counts as that pull
request.

## Install

1. Open `chrome://extensions`.
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and choose this folder. In the built app it is inside the bundle:
   Settings → Integrations → Browser → **Show Extension Folder**.
4. In Task Board, turn on Settings → Integrations → Browser → **Switch to a tab that is already open**.

## How it works

Task Board adds `#taskboard-reuse` to the end of the links it opens. The extension acts only on new
tabs whose address ends in that marker: it looks for another tab on the same page, switches to it
and closes the new one, or, if there is none, removes the marker and leaves the new tab alone.
Every other tab is ignored.

It asks for the `tabs` permission, which Chrome describes as "Read your browsing history", because
finding the tab that already shows a page means reading the addresses of your open tabs. It makes
no network requests and stores nothing.
