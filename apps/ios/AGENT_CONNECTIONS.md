# Agent connections: Moshi and Herdr

Phren manages project memory, skills, findings, tasks, and the graph. The iPhone
app also reads live Herdr session status through an existing Moshi hook.
Moshi beside Phren on the iPhone remains optional for interacting with sessions.

## Implemented connection

Agents → Add computer adds a computer with its own device SSH key and a
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

The phone polls only visible computer or project-session screens, with cancellation, a total
request deadline, response size limits, and explicit stale/disconnected labels.
Live metadata stays in memory. An explicit directory → full store ID/project
mapping connects a tab to a graph. Without an explicit mapping, the deepest
directory component matching one unique attached project recognizes it automatically.
Path boundaries, longest-root matching, and full store identity prevent similarly
named directories or projects from being conflated. Missing
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

Live rows construct a Herdr destination from the hook's observed IDs. When the
latest snapshot contains just one tab in a workspace, the handoff uses only
`workspace`, avoiding a second tab-focus transition after Moshi resumes its card.
Multiple tabs (or an unknown tab count) include the selected tab's ID. The default
server is implicit. No manual link or project mapping is needed to open the tab.
The Agents action is labelled with the destination workspace,
with its view identity tied to the URL across row refreshes. Long-pressing it
can copy that same link for a direct comparison in Safari.
Project → Project session and graph node details → Session discover current
sessions using directory recognition and explicit mappings. A single match stays
visible for selection, as do multiple matches. Discovery and subsequent refreshes
never launch Moshi automatically. Before opening, every discovered-session path
shows the target computer and explains that the workspace URL cannot select it.
Choosing an unmatched session remembers its directory for this project.

Manual tmux/Herdr shortcuts remain available for unsupported discovery targets.
The app encodes each value independently and preserves shortcuts on launch failure.

Moshi's links resume active/minimized session cards; they do not create a
connection and have no public host selector. Matching workspaces across hosts
can therefore be ambiguous. Known workspace collisions show a warning; the user
must have the intended computer connected in Moshi. A unique result among Phren's
configured computers does not establish uniqueness among Moshi's active cards.
The computer check is a workaround, not automatic host switching: the final URL
can still resolve to another computer. Full host selection requires a supported
Moshi API. Do not invent `hostId` parameters or use its internal terminal route.
Phren cannot inspect Moshi's iPhone session cards or share its credentials.
An agent conversation ID is never used as a Herdr server, workspace, tab, or pane.
[Link grammar](https://getmoshi.app/docs/notifications#open-active-sessions-with-deep-links).

### Investigating a wrong-session handoff

Moshi 3.13.0 or newer is required for the `tab` and `pane` parameters. Verify
the installed phone version when workspace navigation resumes the old tab.
The hook version alone does not establish the phone app's capabilities.

`AutomaticSessionTests` captures the actual URL passed to iOS and checks both
switching between live workspace rows and choosing a different tab in a project.
The capture is enabled only in debug simulator UI tests with
`--capture-moshi-links`; it does not intercept links in device builds.

If the outgoing workspace/tab IDs are correct, compare a direct Safari link
using the current hook IDs, first with `workspace` alone and then with `tab`.
This separates Phren's project matching from Moshi's card selection and focus.
An accepted iOS URL-open callback confirms only that the app handled the URL;
it cannot confirm which terminal or Chat View Moshi displayed. A passing
simulator launch test is therefore not physical-device handoff verification.
Regression coverage checks that initial discovery and foreground refresh do not
send a URL, cancelling the computer check sends nothing, and the final explicit
workspace action retains the selected destination after row refreshes.

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
