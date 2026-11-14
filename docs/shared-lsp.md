# One language server for every window

The native app builds one `Desktop` per project window, and each used to
spawn its own language servers. Three Python projects open meant three
copies of the server: three interpreters, three sets of stdlib stubs, three
caches. With `iommi_lsp` over `ty` that was 2× ~250–550 MB per project.

A server that implements LSP multi-root can serve them all from one
process, each project a *workspace folder*. Since the windows live in one
process, the native app now shares such servers.

Measured on two Django projects (dryft, dryft-2), `iommi_lsp` + `ty-semantic`,
one file open in each, driven through `libturbokod.dylib`:

| | processes | footprint |
|---|---|---|
| one server per window | 2× `iommi_lsp` + 2× `ty` | 295 MB |
| shared | 1× `iommi_lsp` + 1× `ty` | 203 MB |

The saving is the per-process half — the runtime, the stdlib, the server's
own code and caches. Each project's analysis is still its own (ty keeps a
database per workspace folder), so a server that's mostly per-project data
saves less.

## Shape

`lsp_shared.mojo`:

* **`LspChannel`** owns the process and the wire. It hands out request ids,
  remembers which session issued each, and sorts every incoming message
  into a per-session inbox.
* **`LspManager`** (`lsp_dispatch.mojo`) stays one per window and keeps all
  its per-window state: documents, the ~70 single-slot in-flight request /
  result fields, diagnostics buckets, the position remapper. It is a
  *session* on a channel — it sends through it and reads only its own
  inbox. That's why sharing happens below the manager rather than by
  sharing a manager: a shared manager would let one window's
  `take_references()` consume another window's reply.
* **`LspPool`** maps a server's identity — `server_key(language, argv)` — to
  its live channel. The host makes one (`tk_lsp_pool_new`) and gives it to
  every window (`tk_desktop_set_lsp_pool` → `Desktop.lsp_pool`). With no
  pool — the terminal frontends, `tk-tui`, tests — `LspManager` keeps its
  private `client` exactly as before; every transport call goes through
  `_send_request` / `_send_notification` / `_poll` / `_reply`, which pick
  one or the other.

Mojo has no module-level mutable globals, so the pool and channels live in
`malloc`-ed storage addressed by an `Int`, like `Desktop` itself. The host
calls every Desktop from its one UI thread, so there is no locking.

A per-project command line — a server resolved from the project's venv —
has a different argv, so it is never shared. That's right: it sees that
project's packages, which a shared one wouldn't.

## Joining

The first window to want a server spawns it, sends `initialize` with its
root, and publishes the channel in the pool. A later window with the same
key joins: its manager goes to `INITIALIZING` with `_join_pending` and, on
each tick, `_complete_join` waits for the channel's cached `initialize`
result, then:

1. sends `workspace/didChangeWorkspaceFolders` adding its root — *before*
   its own didOpens, which were queued while it waited, so the server
   assigns those files to the right folder;
2. runs the cached result through `_on_initialize_response` as if it had
   asked (capabilities, position encoding); the `initialized` that sends
   is dropped by the channel, which allows it once per process;
3. replays every capability registration the server has made so far,
   muted (see below).

A server whose result lacks `workspace.workspaceFolders.changeNotifications`
can't take a second folder, so the joiner falls back to spawning its own
private server (`_fall_back_to_private`). Same if the channel's process
died.

## Routing

| from the server | goes to |
|---|---|
| a response | the session that sent the request (by id) |
| `publishDiagnostics`, `workspace/applyEdit`, `window/showDocument`, `workspace/configuration` | the session with that document open, else the one whose root holds it (innermost root wins), else the active one |
| `window/showMessage` | the session whose project directory the message mentions (innermost wins), else **every** session — a duplicate pop-up beats a missed error |
| `window/showMessageRequest` | the session the message mentions, else the active one (it needs exactly one answer) |
| `$/progress`, `window/logMessage`, `$/logTrace`, `telemetry/event` | every session |
| `client/(un)registerCapability`, `workspace/*/refresh` | every session; only the first answers |
| `workspace/workspaceFolders` | answered by the channel, from every session's root |
| anything else | the active session |

*Active* is the session that last sent the server anything — the window the
user is working in (falling back to the first if that one has left). Pop-ups
carry no document field, so the project they're about is taken from the
text: servers name it by path ("invalid config in <root>/pyproject.toml"),
matched as a whole path so `/p/app` doesn't claim `/p/app2`.

A message delivered to a session that must not answer it is a *replay*:
`_poll` sets `_reply_muted`, and `_reply` / `_reply_error` do nothing while
it's set. The server gets exactly one answer per request.

`didOpen` / `didClose` are reference-counted per URI in the channel, so a
file open in two windows is opened once and closed when the last one
closes it.

An inbox nobody drains (an occluded window doesn't tick) is capped at
`_INBOX_MAX`, oldest dropped.

## Leaving

`begin_shutdown` on a session that isn't the channel's last sends didClose
for its documents, removes its folder, leaves, and reports done at once —
the server keeps running for the others. The last session out first takes
the channel out of the pool (so nobody joins a server that's saying
goodbye), then runs the normal `shutdown` / `exit` handshake;
`finish_shutdown` terminates the process and frees the channel.

LSP ▸ Restart passes `fresh=True` (`Desktop._lsp_spawn_fresh`): joining
the running server would restart nothing. The new server replaces the old
one in the pool; the old one keeps serving the windows already on it until
they leave.

## Turning it off

`TK_LSP_PRIVATE=1` in the app's environment skips handing windows the
pool, so every window spawns its own servers as before.

## Tests

`tests/test_lsp_shared.mojo` plays two (or three) windows — managers with
one pool, rooted in separate scratch dirs — against `mock_lsp.py` with
`tests/fixtures/lsp/shared_multiroot.json`, and asserts on the mock's
request log: one `initialize`, the joiner's folder added, diagnostics and
replies reaching the window that owns them, a registration answered once
but known to every window (including one that joins later), the server
outliving its first window and shutting down with its last, the fallback
for a server without multi-root, and Restart's fresh spawn.
