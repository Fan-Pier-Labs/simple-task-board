# Setting up Task Board on the computer where you use Cursor

These steps are for an AI coding agent to carry out together with its user, on the Mac where the
user runs Cursor agents. They install the app, connect GitHub, Jira and Cursor, and prove that each
connection works.

The app was built on a different computer. Its unit tests pass, pull request status has been
checked against github.com, and the hooks have been run with real Claude sessions. Three things
have never run against the real service: the Cursor hooks, the Cursor deep link, and Jira. Expect
to find a problem in at least one of them. Finding and fixing those is the point of this document.
[What has not been proven](#what-has-not-been-proven) says where to look.

These steps assume the agents run in Cursor. If they run in Claude instead, use
`taskboard config agent claude` and `taskboard install-claude-hooks` in step 4, and expect Claude's
event names in the hook log (`SessionStart`, `UserPromptSubmit`, `Stop`).

## Rules

1. **This repository is public.** Do not commit or post anything from this computer: host names,
   Jira keys, repository names, task titles, names, email addresses, tokens or home-directory
   paths. Use `github.example.com`, `your-team.atlassian.net` and `DEMO-1` in anything you write
   to the repository. Command output in these steps contains real data, so keep it in the
   conversation and out of commits, pull requests and issues.
2. **Sign-in belongs to the user.** Do not run `gh auth login` yourself, and never ask the user to
   paste a token or password into the chat. Ask them to do those steps and wait.
3. **Clicking belongs to the user.** You cannot see the menu bar. Where a step says "ask the
   user", ask one specific question and wait for the answer.
4. **Check tasks are temporary.** Every task you create here has "check" in its title. Remove
   them all in step 6.

Run every command from the root of this repository unless a step says otherwise.

## 1. Build and install

```bash
sw_vers -productVersion     # needs 14.0 or later
swift --version             # needs 5.9 or later
gh --version                # the GitHub CLI; install from https://cli.github.com if missing
swift test                  # every test should pass
scripts/build-app.sh --install
```

The last command builds the app, copies it to `/Applications/TaskBoard.app` and launches it. Then:

```bash
pgrep -x TaskBoardApp && ~/.taskboard/bin/taskboard help | head -3
```

Both must succeed. Use `~/.taskboard/bin/taskboard` for every `taskboard` command below; the app
creates that link each time it starts.

Ask the user: "Is there a new icon made of three small columns in your menu bar, and does clicking
it open an empty board?"

## 2. GitHub

Pull request status comes from the GitHub CLI, which needs to be signed in to the server the
user's repositories live on.

1. Find the server. In a checkout of a repository the user works on, run `git remote get-url origin`
   and take the host name from it. Confirm it with the user.
2. Run `gh auth status`. If that server is not listed as signed in, ask the user to run
   `gh auth login --hostname <server>` in their own terminal, and wait.
3. Tell the app, unless the server is `github.com`:

   ```bash
   ~/.taskboard/bin/taskboard config github-server <server>
   ```

4. Link a real pull request. In that checkout:

   ```bash
   gh pr list --author @me --state open --limit 1 --json url --jq '.[0].url'
   ```

   If that prints nothing, ask the user for the URL of any pull request they can see. Then:

   ```bash
   ~/.taskboard/bin/taskboard add "PR check" --pr <url>
   ```

5. Test finding a pull request from a branch, which is how agents' pull requests get linked on
   their own. Pick a branch in that checkout that has an open pull request:

   ```bash
   ~/.taskboard/bin/taskboard add "Branch check" --workspace <path to the checkout> --branch <branch>
   sleep 75
   ~/.taskboard/bin/taskboard show branch-check | grep '^pr:'
   ```

   A `pr:` line should have appeared. The app adds it the next time it checks GitHub.
6. Ask the user: "On the board, do 'PR check' and 'Branch check' each show a GitHub button with a
   coloured dot, and does clicking it open the pull request?" Green means checks pass, yellow
   running, red failing, purple merged.

## 3. Jira

Jira is read-only: the app shows an issue's status and links to it.

1. Ask the user for their Jira address, and whether it is Jira Cloud (an `atlassian.net` address)
   or a self-hosted Data Center.

   ```bash
   ~/.taskboard/bin/taskboard config jira-site <address>
   ~/.taskboard/bin/taskboard config jira-email <the user's Jira email>   # Jira Cloud only
   ```

   For Data Center, leave the email unset. The token is then sent as a personal access token.
2. Ask the user to create a token and paste it into the app themselves: click the menu bar icon,
   the gear, Integrations, paste it under Jira, click **Save Token**, then **Test Connection**.
   For Jira Cloud the token comes from https://id.atlassian.com/manage-profile/security/api-tokens.
   For Data Center it is a personal access token from their Jira profile. Ask what Test Connection
   said. It should read "Connected as" followed by their name.
3. Ask the user for the key of any issue they can see, then:

   ```bash
   ~/.taskboard/bin/taskboard add "Jira check" --jira <KEY>
   ```

4. Ask the user: "Does the 'Jira check' card show the issue key with its Jira status next to it,
   and does clicking that open the issue?"

## 4. Cursor

This is the part most likely to need a fix.

1. Install the hooks and turn on the hook log, which records exactly what Cursor sends:

   ```bash
   ~/.taskboard/bin/taskboard config agent cursor
   ~/.taskboard/bin/taskboard install-cursor-hooks
   touch ~/.taskboard/hooks.log
   ~/.taskboard/bin/taskboard add "Task Board setup check"
   ```

2. Ask the user to open a **new** agent chat in the Cursor desktop app, in any project, and send
   exactly this:

   > Create a file named taskboard-check.txt containing the word ok, then delete it. This is part
   > of the Task Board setup check.

   Ask them to look at the board while it runs, and to tell you when the agent has finished. A new
   chat matters: an existing chat started before the hooks were installed, so it never received
   its instructions.
3. Read what happened:

   ```bash
   cat ~/.taskboard/hooks.log
   ~/.taskboard/bin/taskboard list
   ```

   Each entry in the log starts with a line naming the app and the chat the call was matched to,
   followed by `in:` (what Cursor sent) and `out:` (what the hook answered). You should see all of
   the following. For each one that is missing, the file to fix is
   `Sources/TaskBoardCore/AgentHooks.swift`.

   | Expect | If not |
   | --- | --- |
   | A `sessionStart` entry whose `out:` has `additional_context` and `env`. | Cursor did not run the hook. Check `~/.cursor/hooks.json`, and Cursor's Hooks output channel for errors. |
   | A `beforeSubmitPrompt` entry whose `in:` has `conversation_id`, `prompt` and `workspace_roots`. | The field names differ from what the code reads. Update the `.cursor` case of `parse` to match the log. |
   | A `stop` entry whose `in:` has `status`. | Same. |
   | `taskboard list` shows a new subtask under `task-board-setup-check`. | See the next two rows. |
   | The new task is a subtask with a short title the agent chose. | If it is a top-level task titled with the start of the prompt, the hooks worked but the agent did not file itself. Ask the user to ask that chat "What were you told about Task Board?". If it knows nothing, Cursor is not passing `additional_context` to the agent. If it knows, the wording in `agentInstructions` needs to be firmer. |
   | The task's status is `needs-attention` or `done` after the agent stopped. | The `stop` hook did not match the task. Compare its `conversation_id` with the task's `cursor_agent`. |

4. Ask the user: "While the agent ran, did its card show a spinner? After it finished, did the
   card turn orange, and did the menu bar icon show a count?"
5. Test the Cursor button. Ask the user: "Click the Cursor button on that card. Did Cursor open
   that exact chat?" If it did not, run the link by hand to see what Cursor does with it:

   ```bash
   ~/.taskboard/bin/taskboard show <task-id> | grep '^cursor_agent:'
   open "cursor://anysphere.cursor-deeplink/agent?id=<that id>"
   ```

   The link is built in `AgentLink.url` in `Sources/TaskBoardCore/TaskItem.swift`. If Cursor needs
   a different link for a local chat, change it there and update `testAgentDeepLinks`.
6. Test carrying on with existing work. Ask the user to open another new chat and send:

   > Keep going on the Task Board setup check: create and delete taskboard-check-2.txt.

   Afterwards `taskboard list` should show this chat attached to an existing task or added as a
   second subtask, not as a new top-level task.
7. Test that questions stay off the board. Ask the user to open a new chat in **Ask** mode and ask
   any question. `taskboard list` should not gain a task.

## 5. Run the doctor

```bash
~/.taskboard/bin/taskboard doctor
```

Every line should start with `✓`. A `!` means that part is set up but has not been exercised, and a
`✗` means it failed; each comes with the next thing to try. The command exits with status 1 if
anything failed.

The first time, macOS may ask whether `taskboard` may read the Jira token from the Keychain. Ask
the user to click **Always Allow**.

## 6. Clean up

```bash
~/.taskboard/bin/taskboard list
```

Remove every task with "check" in its title using `taskboard remove <id>`, subtasks before their
parents. Then turn the hook log off, because it records every prompt:

```bash
rm ~/.taskboard/hooks.log
```

## 7. Report to the user

Tell the user, in a short list: which of GitHub, Jira, the Cursor hooks, agent self-filing and the
Cursor button work; what you changed to make them work; and what still does not.

If you changed code, run `swift test`, rebuild with `scripts/build-app.sh --install`, and repeat
the step that failed. Put the change on a branch and open a pull request against this repository.
Check the diff against rule 1 first.

## What has not been proven

| Part | Risk | Where |
| --- | --- | --- |
| Cursor hook payloads | Field names were taken from Cursor's documentation, not from a real run. | `parse` in `Sources/TaskBoardCore/AgentHooks.swift` |
| Agent self-filing | Depends on Cursor handing the `sessionStart` hook's `additional_context` to the agent, and on the agent acting on it. | `agentInstructions` in the same file |
| Cursor button | The link format may open cloud agents only, not local chats. | `AgentLink.url` in `Sources/TaskBoardCore/TaskItem.swift` |
| Jira | Never run against a real site. Uses `rest/api/2/issue/<KEY>` and `rest/api/2/myself`. | `Sources/TaskBoardCore/Jira.swift` |
| GitHub Enterprise | Works on github.com. On another server it relies on `gh` taking the server from the pull request URL or the git remote. | `Sources/TaskBoardCore/GitHub.swift` |
| Agent paused on an approval prompt | Not detectable: Cursor has no hook for it. The card changes only when the turn ends. | |
