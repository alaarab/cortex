# Agent connections: Moshi and Herdr

Phren manages project memory, skills, findings, tasks, and the graph. The iPhone
app also reads live Herdr session status through an existing Moshi hook.
Moshi beside Phren on the iPhone remains optional for interacting with sessions.

## Implemented connection

Projects → Live sessions adds a computer with its own device SSH key and a
verified host fingerprint. Tailscale provides network reachability; Phren does
not borrow the Moshi app's credentials or tunnel. No Phren gateway is required.
The SSH channel only opens the remote loopback address `127.0.0.1:24543` and
issues `GET /v1/workspaces`. There is no shell or arbitrary route API.

The endpoint was observed on installed `moshi-hook 0.3.19`, which returns
`kind`, `capabilities`, and workspace `groups` with tab `children`. Tab metadata
includes `agentStatus`, `agent`, `cwd`, and optionally `agentPaneCount`. The
adapter supports the default Herdr server, not tmux or named server discovery.
A tab can contain several agents; the screen does not invent per-pane records.
An agent conversation's `sessionId` is **not** a Herdr server/session name and
must not be used as one in a Moshi URL. Unknown states remain unknown.

The phone polls only the visible computer screen, with cancellation, a total
request deadline, response size limits, and explicit stale/disconnected labels.
Live metadata stays in memory. An explicit directory → full store ID/project
mapping connects a tab to a graph; path boundaries and longest-root matching
prevent similarly named directories or projects from being conflated. Missing
stores or projects are shown as unavailable. Preferences reject corrupt or
future schemas without replacing the original data.

The exported SSH authorization line restricts forwarding to the gateway and
disables shell commands. The hook itself offers more capabilities than status;
this is a client limited to reads, not a new server-side read-only credential
scope. The transport exposes no approval, terminal input, or transcript calls.

See [phone setup and tests](README.md#live-herdr-sessions-over-tailscale--ssh),
[Moshi gateway roles](https://getmoshi.app/docs/install-desktop),
[workspace discovery](https://getmoshi.app/docs/debug-multiplexer-chooser), and
[Tailscale setup](https://getmoshi.app/docs/tailscale).

## Optional iPhone handoff

Project → Project session and graph node details → Session configure a tmux or
Herdr destination using Moshi's public URL grammar. Linked live rows expose
that same project shortcut. The app encodes each value independently and shows
failed app launches without deleting the saved shortcut.

Moshi's links resume active/minimized session cards; they do not create a
connection and have no documented host selector. Matching names across hosts
can therefore be ambiguous. Destinations remain manually configured rather
than inferred from the hook's agent conversation IDs.
[Link grammar](https://getmoshi.app/docs/notifications#open-active-sessions-with-deep-links).

## Next integration steps

- Verify setup and the app handoff on a physical iPhone over its tailnet.
- Add named Herdr servers and tmux only after observing their discovery contract.
- Retain provider session/workspace/tab/pane metadata if the desktop registry
  becomes a source. Never execute its `focus` argv from a phone payload.
- Consider reviewed task handoffs after status and project linking are proven.
  Phren can supply context and tasks while Moshi handles terminal interaction.

The CLI's existing `AgentRecord`/`JoinedAgent` and Herdr provider remain in
`packages/cli/src/agents/`. No process supervisor, remote task execution,
transcript collection, new daemon, or webhook notifications are added here.
