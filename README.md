# AIO Control

Flutter control-plane app for the `aio-daemon`. It connects to the daemon over a
relay, lists registered daemons, dispatches commands, and renders the
`ack → log → result` stream in real time.

This app implements **Mode B (relay client)** from
[`flutter-control-app-handoff.md`](flutter-control-app-handoff.md): it is a plain
WebSocket client that dials OUT to a relay's `/control` endpoint, so the phone and
the Mac can be on any networks.

## Architecture

```
lib/
  models/
    envelope.dart        Wire envelope { type, id, payload, daemon, ts }
    daemon.dart          Daemon built from a `register` frame
    command.dart         CommandRun lifecycle: pending → running → done/error
    remote.dart          Remote apps: stream config, windows, apps, error codes,
                         input-channel messages, letterbox coordinate mapping
  services/
    relay_client.dart    WebSocket client: connect, bearer auth, backoff reconnect
    settings_store.dart  Relay URL + control token (token in secure storage)
    remote_session.dart  One WebRTC stream: offer → stream.start → answer, input channel
  state/
    app_state.dart       ChangeNotifier: routes frames by `daemon` id and `id`
  actions/
    action_spec.dart     Catalog of daemon actions and their argument fields
  models/
    system_metrics.dart  Host metrics model + shell-output parser
    file_entry.dart      file.list entry + dir/file result types
  screens/
    home_screen.dart     Relay status header + daemon cards
    daemon_screen.dart   Per-daemon tabs: System · Actions · Terminal · History
    system_screen.dart   Live host dashboard (CPU/RAM/disk/battery/network)
    file_browser.dart    Lazy directory tree + file search (browse / pick)
    file_viewer_screen.dart  View / edit / save a file
    repo_picker.dart     Lists git repos under the workspaces
    git_screen.dart      Git dashboard: status, changes, commits, branches, diff
    pr_screen.dart       Pull requests via gh: list, diff, review, merge
    terminal_screen.dart Interactive shell for a repo (deploy + shell:true)
    remote_apps_screen.dart  Remote tab: permissions, window/display picker, app launcher
    remote_view_screen.dart  Live stream view: touch → mouse, soft keyboard, shortcut toolbar
    dispatch_sheet.dart  Argument form for an action
    command_screen.dart  Live, auto-scrolling log stream + result for one command
    settings_screen.dart Edit relay URL / control token
  theme.dart             Design system (colors, radii, console styling)
```

## Rich actions

The file/git/PR actions open interactive UIs instead of a plain argument form:

- **List directory** — a lazy-loading, expandable directory tree rooted at the
  daemon's workspaces (`file.list` per folder on expand).
- **Read file** — browse the tree *or* search files by name across workspaces,
  then open a syntax-neutral viewer (`file.read`).
- **Write file** — search/pick (or create) a file, edit it inline, and save
  (`file.write`), with unsaved-change protection.
- **Git** — pick a repo, then a dashboard: current branch with ahead/behind,
  changed files (tap for a colored diff), fetch/pull/push, stage-all + commit,
  recent commits (tap to view), and branch checkout. Mutating operations stream
  in the live command view.
- **PR review** — pick a repo, list open PRs via the GitHub CLI, view a PR's
  colored diff, run an AI `pr.review`, check out, or merge (squash/merge/rebase).
  Requires `gh` on the daemon host — the screen detects and guides if it's
  missing or unauthenticated.

Read-only queries (listing, search, status, diffs) are dispatched **untracked**
so they don't fill the History tab; operations you explicitly run (pull, commit,
merge, review) are tracked and stream their output.

## System dashboard

The **System** tab shows a live view of the daemon host — CPU usage (with load
average and core count), memory used/total, storage, battery/AC state, network
(Wi-Fi name or Ethernet interface, IP, and live up/down throughput), model, OS,
and uptime.

The daemon has no metrics action, so these are collected by running a single
shell command (via `deploy` + `shell:true`) and parsing its output; the panel
polls every 3s while it's the visible tab. Network rates are derived by diffing
interface byte counters between polls. macOS is fully supported; Linux is
best-effort (`/proc`-based) and degrades gracefully — only metrics that parse
are shown.

## Terminal

Each daemon that supports the `deploy` action gets a **Terminal** tab — an
interactive shell for a repo on that host:

- Set a working directory (tap the folder bar) or hit **detect** to pull the
  daemon's `workspaces` from `system.info` and pick one.
- Type a command and press enter — it runs as `deploy` with `shell:true`
  (`sh -c "<command>"`) in the current directory; stdout/stderr stream in live.
- `cd` and `clear` are handled locally; **↑/↓** cycle command history.
- The working directory is optimistic — anything outside the daemon's
  workspaces is rejected by the daemon and shown as an error.

> The daemon has no persistent shell session, so each command runs fresh
> (env/shell state does not carry across commands, but the tracked cwd does).

## Remote apps

Daemons that list `stream.start` in their `register.actions` (macOS desktop app
or cgo build, in v1) get a **Remote** tab that streams a desktop window (VS Code,
Android Studio, a browser, …) to the phone over **WebRTC** and controls it.

- The tab checks `stream.config` first. Missing **Screen Recording** permission
  blocks streaming and shows the steps to fix it on the Mac; missing
  **Accessibility** shows a "view only" notice (input is ignored).
- Pick a window or a whole display from `screen.windows` (minimized windows are
  disabled), or **Launch app** from `app.list` (IDEs and browsers pinned), optionally
  opening a project from the workspaces. The list polls for the new window.
- The phone is the WebRTC offerer: recv-only H.264 video + an `input` data
  channel. ICE is gathered fully (3 s cap) before `stream.start`; STUN/TURN
  servers come from the daemon, never the app. Only signaling goes over the relay.
- Gestures: tap = click, double-tap = double-click, long-press = right click,
  one-finger drag = mouse drag, two-finger drag = scroll, pinch = local zoom.
  Coordinates are normalized against the displayed video rect (letterbox bars
  excluded, zoom undone).
- The keyboard button opens the soft keyboard (text is sent as `text`; Enter and
  Backspace as keys). The toolbar has Esc, Tab, arrows, one-shot ⌘ ⌃ ⌥ ⇧
  toggles (⌘ then typing `s` sends ⌘S), and a shortcuts menu.
- A red **LIVE** pill shows while streaming and the Remote tab icon turns red.
  Leaving the view sends `stream.stop` and closes the peer connection. If the
  daemon ends the session or goes offline, you return to the picker.

Without a TURN server (`stream.config` returns STUN only), streaming can fail on
some cellular or symmetric-NAT networks. The view then shows a "couldn't connect
directly" error.

State management is `provider` + `ChangeNotifier`. Every incoming frame is routed
by its top-level `daemon` field (which daemon) and `id` (which command).

## Configuration

Open **Settings** (gear icon) and set:

| Setting | Example | Notes |
|---|---|---|
| Relay URL | `wss://relay.example.com/control` | `ws://` allowed only for local testing |
| Control token | *(secret)* | Sent as `Authorization: Bearer <token>`; must equal the relay's `-control-token` / `AIO_CONTROL_TOKEN`. Stored in the platform Keychain/Keystore. |

The token is **never** stored in the repo or plaintext prefs — it lives in secure
storage on the device.

## Run

```sh
flutter pub get
flutter run                 # pick a device (macOS / iOS / Android)
```

### Local end-to-end test (per the handoff)

```sh
./bin/aio-relay  -addr :9090
./bin/aio-daemon -server ws://localhost:9090/agent
```

Then point the app at `ws://localhost:9090/control`. You should see the daemon
appear with its providers; dispatching `system.info` returns `ack` then a
`result` with `data.workspaces`.

> Cleartext `ws://` to local hosts is enabled via an ATS `NSAllowsLocalNetworking`
> exception (iOS/macOS) for dev only. macOS also needs the network-client
> entitlement, which is set in `macos/Runner/*.entitlements`.

## Test / analyze

```sh
flutter analyze
flutter test
```
