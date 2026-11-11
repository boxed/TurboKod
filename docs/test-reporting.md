# Live test reporting

A test runner can tell the test pane what it's doing while it runs — how many
tests there are, which one is running, how each ended, and why a failure
failed — and the pane shows that as a **results view**: a progress bar, the
test in progress, and below them a list of every test with an icon for its
state (`▸` running, `✓` passed, `✗` failed, `⚠` error, `↷` skipped, `x`
expected failure, `!` unexpected pass) beside the detail of the selected
one — outcome, duration, message, traceback and captured output. A
landscape pane splits side by side (list left), a portrait one stacks (list
on top). The divider drags (a `SplitArea`, with the resize cursor over it in
every look and drawn in each look's own style — see CLAUDE.md's
"Resizable splits"; double click resets it), and each orientation's position is a
setting of its own (`test_split_wide` / `test_split_tall`, thousandths):
`Desktop._sync_test_splits` saves a drag and pushes the config's positions
into every results view each frame, so another pane or window follows. The first failure is selected as it arrives, until the user picks a
test (click, Up / Down, Home / End); Page Up / Down scroll the detail and
Enter opens the selected test. The
toggle is the `[☰ Results]` / `[▤ Output]` button in the pane's title strip;
it's a setting (`config.test_results_view`, off by default), so every window
and every later run follows it. The run keeps going on its pty either way;
the toggle only picks what the body shows, and the title carries the progress
(`Tests — running · 45/120 · 3 failed`) in both.

TurboKod ships a pytest plugin that speaks the protocol, and loads it into
every Cmd+T / gutter-Run pytest. Any other runner can speak it too: it's
"append JSON lines to a file".

## The protocol

When the test pane runs a command it sets **`TURBOKOD_TEST_REPORT`** to a
file path. The runner appends one JSON object per line to it (UTF-8, `\n`
terminated). The pane tails the file each frame; a line counts once its
newline is written, so a partial write is harmless. Lines that aren't JSON
objects, unknown events, and unknown fields are ignored, so the protocol can
grow without breaking older runners or older TurboKods.

| Event | Fields | Meaning |
|---|---|---|
| `collected` | `total` | How many tests the run will report — the progress bar's 100%. May be sent again; the last wins. |
| `start` | `id`, `file`, `line` | A test began. The pane shows it as "in progress" until its `result`. |
| `result` | `id`, `outcome`, `file`, `line`, `duration_ms`, `message`, `output` | A test ended. `outcome` is `passed`, `failed`, `error`, `skipped`, `xfailed` or `xpassed`. For `failed` and `error`, `message` (one line) and `output` (traceback, captured output — anything) are shown. |
| `finish` | `exit_code` | The run is over. |

`file` is absolute (or relative to the run's directory), `line` 1-based and 0
for none. A failure's header in the results view opens `file:line`; paths in
its `output` (`File "...", line N`, `path:N`) are links as in the terminal
view.

A runner that doesn't report leaves the file empty, and the results view says
so and points at the Output view.

Example, from a shell:

```sh
echo '{"event": "collected", "total": 1}' >> "$TURBOKOD_TEST_REPORT"
echo '{"event": "result", "id": "smoke", "outcome": "failed", "output": "boom"}' >> "$TURBOKOD_TEST_REPORT"
```

In the macOS-style and Mac OS 9 looks the view is native: the core paints
blank cells and hands the header, list and detail to the host as host items,
which `TestResultsHost` fills with the look's own views (a table with SF
Symbols and a text view with links in the macOS look; Platinum list wells and
a Mac OS 9 progress bar in the Mac OS 9 one). See docs/native-ui.md,
"Framework chrome and the test results".

## Where it lives

- **`src/turbokod/test_report.mojo`** — `TestReport`, the reader: keeps every test
  in the order it appeared (a second `result` for an id replaces the first,
  counts included), and tails the file with `pread` from a remembered offset (a bounded amount per tick),
  splits lines, applies events. Also the environment the pane hands a run
  (`reporting_env`) and the report paths.
- **`src/turbokod/test_results.mojo`** — `TestResultsView`, the view: the
  split (`is_landscape`: a cell is half as wide as tall), the list, and the
  selected test laid out as detail rows (escape sequences stripped, wrapped
  by cells, cached per report version, width and selection), each half with
  its own `ScrollBarArea`; clicks map to a selection or a link. It paints into the same terminal-font grid the pane would
  have put its `Vt` in, so its coordinates are the grid's.
- **`src/turbokod/data/pytest_plugin/turbokod_pytest.py`** — the pytest
  plugin. Bundled with the rest of `data/` into the app's Resources.

Both panes that run tests embed a `TestResultsView`:

- **`TestPane`** (pty-backed): each run gets a fresh file,
  `~/.cache/turbokod/test-reports/<pid>-<ms>.jsonl`, passed through
  `/usr/bin/env` in front of the command so the `$` banner still shows just
  the command. The file is deleted at the next run and at `release`.
- **The tmux tests pane** (`TerminalPane` with `tests`, the default when
  `terminal_tmux` is on): the file is named after the session,
  `test-reports/tmux-<session>.jsonl`, and the variables go in the session's
  environment (`run_env`). Because the name is derived from the session, a
  pane re-attached after a restart reads the report again from the start
  (`TestResultsView.attach`) and picks up where the run is. Re-run starts the
  file over; closing the pane (which kills the session) deletes it, a detach
  doesn't.

## The pytest plugin

The pane copies the bundled file to `~/.cache/turbokod/pytest_plugin/`
(when it differs) and points `PYTHONPATH` at the copy, so Python's
`__pycache__` lands there and not inside the signed app bundle.

Loaded with `PYTHONPATH=<plugin dir>:$PYTHONPATH` and
`PYTEST_ADDOPTS="$PYTEST_ADDOPTS -p turbokod_pytest"` — environment only,
nothing on the command line. It does nothing unless `TURBOKOD_TEST_REPORT`
is set, and **removes the variable** from `os.environ` in `pytest_configure`,
so a pytest a test spawns in a subprocess (pytester, say) loads the plugin
through the inherited `PYTEST_ADDOPTS` but doesn't write into this run's
report.

- One test produces three reports (setup, call, teardown); the plugin folds
  them into one `result`, sent with the teardown, which always comes last.
  The worst phase wins: a passing test whose teardown fails is an `error`.
- `output` is the failure's `longreprtext` plus its captured sections
  (stdout, stderr, log).
- A collection error is a `result` with outcome `error` and the module as id.
- **pytest-xdist**: only the controller reports. It doesn't collect itself,
  so `total` comes from the first worker's
  `pytest_xdist_node_collection_finished`; results arrive through the usual
  hooks. Workers have `workerinput` and skip registration (they never see the
  variable anyway). xdist's `[gwN] platform -- Python …` header line is
  dropped from the output.

If the plugin directory isn't there (a frontend running away from its
resources), the pane still sets `TURBOKOD_TEST_REPORT` but doesn't touch
`PYTHONPATH` / `PYTEST_ADDOPTS`, so pytest isn't asked to load a plugin it
can't import.

## Tests

`tests/test_test_report.mojo` covers the reader (partial lines, garbage,
re-attach), the view (progress row, failure rows, link clicks) and the pane's
plumbing end to end with a `/bin/sh` "runner" that writes to the file.
