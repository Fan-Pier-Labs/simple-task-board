# Notes for AI agents working in this repository

Task Board is a macOS menu bar app, written in Swift, that shows what many coding agents are
working on. `README.md` explains what it does and how tasks are stored.

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
GitHub, Jira and Cursor, and proves each one works.

## Working on the code

```bash
swift build
swift test
scripts/build-app.sh --install   # rebuild, replace /Applications/TaskBoard.app, relaunch
```

- `Sources/TaskBoardCore`: the model, markdown storage, status roll-up, and the GitHub, Jira and
  Cursor integrations. No UI. This is what the tests cover.
- `Sources/TaskBoardApp`: the menu bar app (SwiftUI inside an AppKit shell).
- `Sources/taskboard`: the command line tool that agents and hooks use to write tasks.

To look at the UI without clicking through it, render it to an image:

```bash
TASKBOARD_HOME=examples/demo swift run TaskBoardApp --snapshot /tmp/board.png --remote examples/demo/remote.json
```

Add `--settings integrations` (or `general`, `columns`) for the settings window, `--layout list`,
`--dark`, `--expand <task-id>` and `--details <task-id>`.

Things to keep true:

- The app only reads task files, apart from writing a pull request link it discovers. Creating
  and changing tasks goes through the `taskboard` command.
- Jira is read-only. The client sends `GET` requests and nothing else.
- A hook must never get in an agent's way: `taskboard hook` always exits 0 and prints valid JSON.
- Titles are at most 50 characters.
