# LSP conformance: how the client is verified

There is no conformance suite for LSP **clients**. The spec ships no TCK, and
what Microsoft publishes — `vscode-languageserver-node`, `lsprotocol` — tests
the reference *server* library. Every editor in this space validates by hand:
fixtures plus real servers. So this is built, not downloaded.

Three layers, cheapest first. Each catches a different class of bug and none
subsumes another.

## Layer 1 — spec-coverage audit (`make lsp-coverage`)

The spec repo publishes [`metaModel.json`][meta]: every request,
notification, structure, property and union variant as data. That file is the
only thing that turns "do we cover most of the protocol?" into a number.
`scripts/lsp_spec_coverage.py` reads the vendored copy at
`tests/fixtures/lsp/metaModel.json` and diffs it against the source.

```sh
make lsp-coverage          # the report, with the unread-property heuristic
make lsp-coverage-check    # the gate — part of `make check`
make lsp-coverage-update   # re-triage after a deliberate change
make update-lsp-metamodel  # refresh the vendored spec
```

Current state: **76 of 95 methods implemented**, 21 covered by a scenario
fixture, and **zero untriaged** — every unimplemented method sits in one of
two labelled buckets:

* **Declined** (12) — out of scope by design: semantic tokens (we have our own
  TextMate highlighter, and don't advertise it), notebooks (no notebook
  surface in either frontend), `$/setTrace` (we never enable server tracing,
  though the inbound `$/logTrace` *is* handled), multi-root workspace folders
  (one root per window), 3.18's `rangesFormatting` and virtual documents.
* **Deferred** (7) — real gaps needing work *above* the protocol layer, each
  listed with what it would take. The substantive ones are
  `workspace/diagnostic` (workspace-wide pull diagnostics, needs a
  project-diagnostics pane) and the `workspace/will{Create,Rename,Delete}Files`
  trio (they return edits to apply *before* the operation, so the file-tree
  action has to become two-phase async — `didRenameFiles` covers the common
  case today).

The split matters: filing a deferral as a decision is how a backlog
disappears.

A method counts as implemented on one of three evidence tiers, and the report
labels which:

| tier | meaning |
| --- | --- |
| `send-site` | the literal sits at a `_send_request` / `_send_notification` call. Exact — both funnel every outbound message. |
| `dispatch` | the literal is compared against an inbound `method`. How server→client traffic is routed. |
| `literal` | the literal appears somewhere in the LSP sources or `desktop.mojo`. Weakest, and necessary: `request_navigation(method, …)` covers typeDefinition / implementation / declaration, and the hierarchy flows pass their methods as arguments, so those read as unimplemented without it. |

`_capability_key_for_method` is excluded from the `literal` tier — it maps
*every* feature method to its provider flag, including ones we never send, so
its body would otherwise match everything.

The gate fails when a method stops being implemented, loses its fixture, or
the vendored spec gains a method the baseline hasn't triaged. It deliberately
does **not** gate on the unread-property heuristic: that shifts with
unrelated string literals, and a check that cries wolf gets muted.

## Layer 2 — scripted server + fixture corpus (`tests/test_lsp_conformance.mojo`)

`tests/fixtures/mock_lsp.py` is a real LSP server process that does real
framing and answers from a JSON scenario. Everything in the suite spawns it
and drives `LspManager`, so the payload travels the whole production path —
spawn, `Content-Length` framing, dispatch, the parse functions, the carriers.
That is what separates these from the parse-function unit tests in
`tests/test_lsp.mojo`: those hand a JSON literal straight to `_parse_x`, so
they cannot catch anything that goes wrong *between* the wire and the parser.

Scenarios are data, not code — see the mock's docstring for the format and
the `$`-directives (`$error`, `$raw`, `$no_reply`, `$split`, `$bad_length`,
and `$SELF` for the document URI a checked-in fixture can't hardcode). The
optional request log (argv 2) records what the client *sent*, which is how
the outbound half gets asserted. Note that scenario and log go on **argv,
not the environment**: `LspProcess.spawn` forwards an allowlist of parent env
vars, so a test-only variable silently never arrives.

Two families:

**Spec-shape coverage** (`shapes_*.json`) — the union variants the spec
permits. A real server picks one and never changes: `textDocument/definition`
is `Definition | DefinitionLink[] | null` where `Definition = Location |
Location[]`, and clangd returns `Location`, gopls `LocationLink[]`, pyright
`Location[]`. No amount of real-server testing reaches the rest. Same for
`Hover.contents` (`MarkupContent | MarkedString | MarkedString[]`, where
`MarkedString` is itself `string | {language, value}` — four shapes) and
completion's `CompletionItem[] | CompletionList`.

**Adversarial** (`adversarial_*.json`) — nulls where objects are declared,
wrong types, missing required fields, ranges past EOF, inverted and negative
ranges, split frames, non-JSON bodies, requests never answered. In practice
this family catches more than spec breadth does, because real servers violate
the schema constantly. The contract is: drop the malformed entry, keep the
valid ones, never crash, and never produce a column from garbage.

**Refusals** (`gaps_*.json`) pin the *shape of a failure* where degrading
gracefully is the whole contract.
`gaps_resource_operations.json` is the worked example: a WorkspaceEdit whose
`documentChanges` also creates / renames / deletes files is refused
**entirely**, never half-applied. A rename plus its reference rewrites is one
atomic refactor; applying only the text edits leaves the project referring to
a file that was supposed to move — broken in a way that doing nothing is not.
This is the one place where "parse what you can" is the wrong instinct.

## Layer 3 — real-server matrix (not built)

`src/turbokod/data/languages.json` already carries 156 languages and 159
distinct server binaries (Helix-derived, see `make update-lsp-list`), which is
the matrix definition. What's missing is a `make lsp-matrix` that spawns a
spectrum of real servers — gopls, rust-analyzer, clangd,
typescript-language-server, pyright, jdtls, lua-language-server, zls, texlab,
yaml-language-server — and asserts the same baseline for each: handshake
completes, didOpen produces diagnostics on a deliberately-broken fixture,
hover / definition / format return sane results. Gate on binary presence, and
keep it out of `make check` (it needs the toolchains installed).

This layer catches the per-server weirdness no spec reading predicts —
clangd's `offsetEncoding` extension, jdtls' non-standard extensions,
rust-analyzer's post-initialize dynamic registration. The three real-server
tests that exist today (`mojo-lsp-server` handshake, `ty` quickfix, `taplo`'s
`workspace/configuration` probe, all in `tests/test_lsp.mojo`) are its seed;
each was written after a real bug, which is the argument for the layer.

## What the layers found

Both layers earned their keep immediately. Every item below was a live defect
or a real missing capability, found by the audit or by a fixture, and fixed:

| gap | why it mattered |
| --- | --- |
| **Position encoding not converted** | The bug that prompted all of this — see the next section. |
| **`WorkspaceEdit.documentChanges` unparsed** | The form rust-analyzer and gopls *prefer*. Per spec a server may only use the form the client advertised, so we now advertise it and parse it; before, their renames and quickfix edits arrived degraded or not at all. `resourceOperations` is deliberately still withheld. |
| **No `shutdown`/`exit` handshake** | We went straight to SIGTERM. rust-analyzer and jdtls flush caches and workspace state on shutdown; killing them mid-flush makes the *next* session re-index or start from a partial cache. Implemented as a poll state machine so no UI path waits on it — see [Closing without waiting](#closing-without-waiting). |
| **`codeAction/resolve` missing** | rust-analyzer's default shape is actions with a title, a `data` blob and no `edit`. The host keeps only actions it can apply, so **every** one was filtered out: an empty quick-fix menu on a buffer full of fixable diagnostics. Resolution happens inside the manager before the list is published, so the host needed no changes; a resolve that never answers publishes a partial list after `_CA_RESOLVE_TIMEOUT_MS` rather than hanging the menu on "Loading fixes…". We now also declare `codeAction.dataSupport` + `resolveSupport.properties: ["edit"]`, which is the honest description of what we do and tells a server exactly what it may defer. |
| **`workspace/*/refresh` answered MethodNotFound** | These are server→client *requests*, and MethodNotFound is worse than useless: the server stops asking, so stale inlay hints and code lenses sat there until the buffer's line count happened to change — for a build finishing, possibly never. Now answered with null plus a flag the host drains to drop its debounce key. The diagnostics variant clears the "already pulled" record, which re-arms the host's existing gate with no host change at all. |
| **`documentLink/resolve` missing** | `DocumentLink.target` is optional; the parse *dropped* targetless links, so a `vscode-json-language-server` `$ref` was silently un-clickable. Publication isn't gated on the resolves (links are decorative) and a link with an empty target still never reaches the host — a dead underline is worse than no underline. |
| **`didRenameFiles` / `didDeleteFiles` missing** | pyright and typescript-language-server rewrite every import of a renamed module on the rename notification, and do nothing without it. Delete keeps stale symbols out of Find Symbol and go-to-definition. |
| **`$/logTrace` dropped** | A server's only channel for "here is what I just did"; now routed to the same capture the info window shows for `window/logMessage`. |

Two smaller ones the fixtures pinned as *contracts* rather than changing:
a diagnostic with a valid range but no `message` (spec-required) is **kept**
with an empty message, because a squiggle in the right place beats silence;
and a `SnippetTextEdit` is skipped, because inserting its raw `$1`
placeholders as literal text would be worse than not applying it.

## Closing without waiting

The handshake is `shutdown` request → response → `exit` notification, and the
server exits on its own. That takes single-digit milliseconds against a
healthy server and up to the grace budget (300 ms for the response, then
200 ms to exit) against a wedged one. Nothing in the UI may wait on it, so
it's a poll state machine rather than a blocking call:

```
begin_shutdown()   →  sends `shutdown`, returns immediately
shutdown_poll()    →  advances; True once the child exited or its budget ran out
finish_shutdown()  →  closes the fds; SIGTERMs a straggler
```

The budgets are wall-clock deadlines, not iteration counts, so the caller's
polling rate can't shorten or extend them.

Three callers, three different "later":

* **Native window close** — `tk_desktop_begin_close(h)` terminates every
  child except the LSP transports and releases the libonig handles, the
  window goes away, and `drainClosingDesktop` in the Swift host re-arms a
  25 ms `asyncAfter` calling `tk_desktop_close_poll(h)` until it reports done
  (or a 2 s backstop), then `tk_desktop_free(h)`. This works because the app
  deliberately outlives its windows
  (`applicationShouldTerminateAfterLastWindowClosed` is False), so there *is*
  a runloop to finish on. Freeing happens on every branch, including the
  `[weak self]` failure path — the handle owns child processes, so stranding
  it would be the leak the teardown exists to prevent.
* **Retiring one server while the app runs** — LSP ▸ Restart, or a Settings
  change to a server's argv. `Desktop.retire_lsp_manager` pulls it out of
  `lsp_managers` (so the next frame no longer sees it) and parks it on
  `_closing_lsp`, which `process_external_changes` drains. Before this,
  Restart froze the editor until the old server answered — and the Settings
  path did it mid-keystroke.
* **No "later" at all** — the terminal frontend (the process is exiting), a
  Cmd+Q cascade (`applicationShouldTerminate` returns `.terminateNow`), and
  tests. These use the blocking `shutdown()` wrapper. The TUI can't defer,
  but it can avoid waiting *silently*: `app.stop()` restores the terminal
  first, so a slow server used to look like the shell prompt hanging for no
  reason. `_shutdown_with_notice` now paints a centered "Shutting down
  language servers…" box over the last frame — but only after 150 ms of
  quiet, because the common case finishes in single-digit milliseconds and
  flashing a box on every quit would be worse than the silence it replaces.

## Position encoding

The bug that prompted all of this, and the reason layer 2 exists.

The editor reasons in **byte** columns. LSP's `Position.character` is an
offset in the *negotiated* encoding — `utf-8`, `utf-16` (the spec **default**)
or `utf-32`. We advertise utf-8 first in `general.positionEncodings`, but that
is a request, not a guarantee: a server that never implemented 3.17 capability
negotiation silently keeps utf-16. Then every column crossing the transport is
wrong by the byte-vs-unit delta on any line containing multibyte text — an em
dash is 3 bytes but 1 UTF-16 unit, an emoji 4 bytes but **2** (a surrogate
pair, so it differs from utf-32 too).

The consequences ranked by damage: a rename or formatting `TextEdit` splices
at the wrong offset and **corrupts the line**; a hover or definition asks
about the wrong token; a diagnostic underlines the wrong span. Before the fix
the negotiated encoding was recorded and *logged* and nothing else, so all
three were live against every server that didn't honor the utf-8 request.

`lsp_position.mojo` holds the conversion — pure, per line, with `LineTable`
indexing a document's line starts once. `_PositionRemapper` in
`lsp_dispatch.mojo` applies it as a **blanket JSON walk at the transport
boundary**, in both directions:

* outbound through `_send_request` / `_send_notification`, which every
  outbound message funnels through;
* inbound at the top of the response dispatch, plus the notification and
  server-request branches (`publishDiagnostics` ranges, `workspace/applyEdit`
  WorkspaceEdits, `window/showDocument` selections all reach buffers).

Why a blanket walk rather than a conversion at each of the ~16 position-building
and ~30 result-parsing sites: LSP nests Positions in a *lot* of shapes, and a
per-site fix has to be remembered at every new site forever. A Position is
unambiguously identifiable — an object carrying integer `line` and
`character` — so one walk covers all of them. The two directions being the
*same* walk is what makes round-tripping opaque server data correct:
`Command.arguments` and `completionItem/resolve`'s echoed item are re-encoded
exactly as they were decoded.

Three details that are load-bearing:

1. **URI context.** A position's document comes from the enclosing object's
   `uri` / `targetUri` / `textDocument.uri`, or from the **key** when
   descending a `WorkspaceEdit.changes` map. Results whose positions are
   implicitly about the request's own document (hover range, formatting
   edits, inlay hints, folding ranges — no URI on the wire) fall back to an
   `id → uri` map recorded at send time from the outbound params. Taking it
   from the params rather than a per-request `_x_path` field means every
   request, including ones added later, gets it for free. With no resolvable
   URI the value is left alone — a wrong column beats a guessed one.
2. **The line index is epoch-cached.** Rebuilding it per request would
   re-scan every open buffer on every keystroke-triggered completion.
   `_remap_epoch` is bumped by the didOpen / didChange / didClose paths and
   the cache refreshes lazily. Open buffers are seeded from `_doc_texts`, not
   read from disk: a dirty buffer's columns must be converted against the text
   the *server* was given.
3. **Clamping and snapping.** A `character` past the line length clamps to
   the line length (per spec — servers emit a huge number for
   "to end of line"). A value landing inside a codepoint, or between the
   halves of a surrogate pair, snaps to that codepoint's start. You cannot
   address half a character in either direction, and a converted column must
   never split a UTF-8 sequence.

Everything is a no-op under utf-8, which is what the majority of servers we
target actually negotiate — `test_server_negotiating_utf8_passes_columns_through`
is the control that pins the conversion to the negotiated encoding rather than
letting it run unconditionally.

[meta]: https://github.com/microsoft/language-server-protocol/tree/gh-pages/_specifications/lsp/3.18/metaModel
