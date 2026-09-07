# Agent connections: Moshi and Herdr

Design notes for the next iteration. The iPhone app currently edits agent
instructions and skills; it does not list or control live desktop agents.

## Start with an integration

Keep phren responsible for project memory, skills, findings, tasks, and the
graph. Use Moshi for the live terminal, chat, and approvals the user already
has. The CLI already has `AgentRecord`, `JoinedAgent`, and a Herdr discovery
provider in `packages/cli/src/agents/`. A phone adapter can build on that
contract without implementing another process supervisor.

Moshi's public links resume active/minimized session cards. Herdr links can
carry session, workspace, tab, and pane IDs; tmux links carry session and
optionally window/pane. They cannot create a saved connection and have no
public host selector, so matching names across hosts are ambiguous. Keep
host identity visible and ask the user to open the intended connection when
there is no unique handoff. Do not use Moshi's internal terminal route.
[Documented link grammar and limitations](https://getmoshi.app/docs/notifications#open-active-sessions-with-deep-links).

The Herdr provider should retain session/workspace/tab/pane IDs as structured
provider metadata; its existing `focus` command is a desktop action and must
never be executed from a phone payload. Moshi already uses Herdr's session
and workspace context in its agent events.
[Moshi's Herdr integration](https://getmoshi.app/docs/herdr).

## Read-only status bridge

Proposed first payload: protocol version, host ID, observed-at time, and
agents with stable provider IDs, label, status, project/store identity, and
optional structured handoff metadata. Show disconnected/stale explicitly;
an empty successful snapshot means no agents, not a connection failure.
Resolve working directories to projects on the host. Do not infer a store
from its display name or send full transcripts just to show status.

Transport still needs a decision: an authenticated host bridge over a
private network, or a narrowly scoped SSH tunnel. iOS cannot borrow another
app's SSH credentials or its existing tunnel. Keep live state out of Git;
the store repo remains the durable memory layer.

Moshi documents a loopback gateway at port 24543. Its `/events` WebSocket is
session-context oriented, and transcript streaming is a separate route. This
is a candidate adapter, not evidence of a stable remote all-agent API; verify
the supported discovery contract before depending on it. Keep the gateway
private and use its documented tunnel path.
[Gateway behavior](https://getmoshi.app/docs/debug-gateway).

## What to decide together

1. Where agents actually run: this Mac, another host, or several hosts; and
   which sessions use Herdr versus tmux.
2. Whether the first phone view needs all agents or only agents for the open
   project. Start with status and a Moshi handoff.
3. Whether task assignment is useful after that. A reviewed task handoff can
   build on phren's tasks without taking ownership of terminal sessions.

No remote execution, new daemon, webhook notifications, or credential sharing
has been enabled by this iteration.
