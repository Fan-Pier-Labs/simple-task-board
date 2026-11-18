# HTTP API

While Task Board is running it serves a small HTTP API on this machine, so that agents, scripts and
other tools can read the board and report to it. It does the same things as the `taskboard`
command, and both follow the same rules.

Use the command when you can: it works whether or not the app is running. Use the API from
something that cannot run the command, such as a script in another language or a tool that only
speaks HTTP.

## Reaching it

- **Address:** `http://127.0.0.1:47821`. Change the port in Settings → Agents → API, or with
  `taskboard config api-port <number>`.
- **Token:** every call except the health check must send the contents of `~/.taskboard/api-token`
  as a bearer token. The app creates that file, readable only by you, the first time it starts.
- **Format:** JSON in, JSON out.

```bash
TOKEN=$(cat ~/.taskboard/api-token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:47821/v1/tasks
```

`taskboard api` prints the address, the token's path and whether the API is answering.

The API listens on the loopback address only, so nothing on another machine can reach it. It
refuses any request that carries an `Origin` header or names a host other than `127.0.0.1` or
`localhost`, which keeps web pages out even before the token is checked. Turn it off altogether in
Settings, or with `taskboard config api off`.

## Tasks

| Call | Does |
| --- | --- |
| `GET /v1/health` | Says whether the app is there. Needs no token. |
| `GET /v1/tasks` | Every top-level task, most recently active first, each with its `subtasks`. |
| `POST /v1/tasks` | Creates a task. Returns `201` and the task. |
| `GET /v1/tasks/<id>` | One task, with its subtasks. |
| `PATCH /v1/tasks/<id>` | Changes the fields you send. Returns the task. |
| `DELETE /v1/tasks/<id>` | Deletes a task. Returns `204`. Refused with `409` while it has subtasks. |

Fields you can send when creating or changing a task. All are strings. In a `PATCH`, `null` clears
a field.

| Field | Meaning |
| --- | --- |
| `title` | At most 50 characters. Required when creating. |
| `status` | `idle`, `working`, `needs-attention` or `done`. |
| `reason` | Why it needs attention. Cleared when the status changes to anything else. |
| `parent` | Id of a top-level task, making this a subtask. |
| `column` | A column's name or id. `null` or `auto` lets the task place itself. |
| `jira` | Jira issue key. |
| `pr` | Pull request URL. |
| `workspace`, `branch` | The checkout and branch the work happens in. The board finds that branch's pull request by itself. |
| `body` | The markdown description. Replaces what is there. |
| `note` | A paragraph appended to the description. |

A task comes back like this:

```json
{
  "id": "add-saved-cards",
  "title": "Add saved cards",
  "status": "needs-attention",
  "reason": "Which card vault?",
  "parent": "revamp-checkout",
  "column": null,
  "jira": null,
  "pr": "https://github.example.com/team/app/pull/9",
  "agent": { "app": "claude", "session": "chat-123", "link": "claude://resume?session=chat-123" },
  "workspace": null,
  "branch": null,
  "body": "",
  "created": "2026-11-18T18:40:00Z",
  "updated": "2026-11-18T18:41:12Z",
  "unfiled": false,
  "subtasks": []
}
```

`unfiled` is true while a card is still the stand-in made from a chat's first prompt.

## Agent chats

An agent identifies itself by its session id: the one its app's hook handed it when the chat
started. With that, it never needs to know a task's id.

| Call | Does |
| --- | --- |
| `POST /v1/tasks` with `"session"` | Creates a task and files the chat under it. Add `"parent"` to make it a subtask. |
| `POST /v1/sessions/<session>/attach` with `{"task": "<id>"}` | Files the chat under an existing task. |
| `POST /v1/sessions/<session>/dismiss` | The chat is not work: takes it off the board. Returns `204`. |
| `GET /v1/sessions/<session>` | The task the chat is filed under. |
| `PATCH /v1/sessions/<session>` | Changes that task. Takes the same fields as `PATCH /v1/tasks/<id>`. |

Send `"agent": "claude"` or `"agent": "cursor"` with a session the board has not seen before, so
the card's button opens the right app. Without it, the app chosen in Settings is assumed.

A typical run:

```bash
API=http://127.0.0.1:47821
AUTH="Authorization: Bearer $(cat ~/.taskboard/api-token)"

# File this chat as a new piece of work under an existing task.
curl -s -X POST -H "$AUTH" $API/v1/tasks \
  -d '{"title": "Add saved cards", "parent": "revamp-checkout", "session": "chat-123", "agent": "claude"}'

# Record the pull request.
curl -s -X PATCH -H "$AUTH" $API/v1/sessions/chat-123 \
  -d '{"pr": "https://github.example.com/team/app/pull/9"}'

# Blocked on the user.
curl -s -X PATCH -H "$AUTH" $API/v1/sessions/chat-123 \
  -d '{"status": "needs-attention", "reason": "Which card vault?"}'

# Finished.
curl -s -X PATCH -H "$AUTH" $API/v1/sessions/chat-123 -d '{"status": "done"}'
```

## Errors

A refused call returns a status and `{"error": "<what is wrong>"}`.

| Status | Means |
| --- | --- |
| `400` | The request is malformed, names an unknown field, or breaks a rule such as the title length. |
| `401` | The token is missing or wrong. |
| `403` | The request came from a web page, or named a host other than this machine. |
| `404` | No such task, session or path. |
| `405` | That path does not take that method. |
| `409` | The change conflicts with the board as it is, such as deleting a task that has subtasks. |
| `413` | The request is larger than 1 MB. |
