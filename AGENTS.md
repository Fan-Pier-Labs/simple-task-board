# Notes for AI agents working in this repository

Task Board is a macOS menu bar app, written in Swift, that shows what many coding agents are
working on. Agents can run in Cursor or in Claude. `README.md` explains what it does and how tasks
are stored.

## This repository is public

Nothing from the computer you are running on may end up in it. That covers company and internal
host names, Jira keys, repository names, task titles, people's names, email addresses, tokens and
home-directory paths.

- In code, tests, docs, examples, screenshots and commit messages, use made-up values:
  `example.com`, `github.example.com`, `your-team.atlassian.net`, `DEMO-1`.
- The output of `taskboard doctor`, `taskboard list`, `taskboard config`, `gh`, and the file
  `~/.taskboard/hooks.log` all contain real data. Read them to diagnose a problem. Do not paste
  them into a commit, a pull request or an issue.
- Before you commit, search your diff for the real host names and keys you have seen.

## Setting the app up on the computer where it will be used

Follow [docs/work-computer-setup.md](docs/work-computer-setup.md). It installs the app, connects
GitHub, Jira and the agent app, and proves each one works.

## Working on the code

```bash
swift build
swift test
scripts/build-app.sh --install   # rebuild, replace /Applications/TaskBoard.app, relaunch
```

- `Sources/TaskBoardCore`: the model, markdown storage, status roll-up, and the GitHub, Jira,
  Cursor and Claude integrations. No UI. This is what the tests cover. `AgentHooks.swift` handles
  both apps' hooks; `HookInstaller.swift` edits their settings files.
- `Sources/TaskBoardApp`: the menu bar app (SwiftUI inside an AppKit shell).
- `Sources/taskboard`: the command line tool that agents and hooks use to write tasks.
- `extension/`: the Chrome extension that switches to an already-open tab. Its `MARKER` must
  match `BrowserTabReuse.marker` in `Config.swift`.
- `docs/api.md`: the HTTP API. `BoardAPI.swift` routes requests, `LocalAPIServer.swift` is the
  socket, and `TaskEdit.swift` holds the rules for changing a task, which the command line tool
  uses too. Change a rule there, not in a caller.

To look at the UI without clicking through it, render it to an image:

```bash
TASKBOARD_HOME=examples/demo swift run TaskBoardApp --snapshot /tmp/board.png --remote examples/demo/remote.json
```

Add `--settings integrations` (or `general`, `columns`, `agents`) for the settings window, `--layout list`,
`--dark`, `--expand <task-id>` and `--details <task-id>`.

Things to keep true:

- The app only reads task files, apart from writing a pull request link it discovers. Creating
  and changing tasks goes through the `taskboard` command.
- Jira is read-only. The client sends `GET` requests and nothing else.
- A hook must never get in an agent's way: `taskboard hook` always exits 0, and prints valid
  JSON or nothing. It runs after every Claude tool call, so it must stay fast and write a task
  file only when something changed.
- Installing hooks changes only the hook entries in the app's settings file. It never adds
  permission rules.
- Titles are at most 50 characters.
- The API stays on the loopback address, behind its token, and refuses requests from web pages.

To test the extension, drive a throwaway Chrome for Testing over the DevTools protocol, started
with `--headless=new --load-extension=<path> --use-mock-keychain --password-store=basic` and its
own `--user-data-dir`. Without the mock keychain it asks the user for their login keychain.
