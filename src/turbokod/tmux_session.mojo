"""tmux sessions behind the terminal panes, so a shell outlives the app.

With ``config.terminal_tmux`` on (the default when tmux is installed), a
``TerminalPane`` doesn't run ``$SHELL`` on its pty: it runs a tmux *client*
attached to a session of its own. The shell — or the ``claude`` running in
it — lives in the tmux server, so quitting or restarting the editor only
detaches the client (``PtyProcess.terminate`` SIGTERMs it, which tmux
treats as a detach). Opening the project again re-attaches every session
that belongs to it.

The server is the user's default one (what a bare ``tmux`` talks to), so
``tmux attach -t turbokod-claude`` — or an iPhone SSH app's session list —
reaches a pane from anywhere. Sharing it shapes the options:

* the ones that make tmux invisible in a pane are set on turbokod's own
  sessions only (``_session_options``, on every attach): no status line,
  no prefix key, and mouse on — but only for a program that asks for
  mouse reports: otherwise the pane keeps wheel and drag to itself and
  scrolls a capture of the history (``tmux_history``), so selecting and
  scrolling work as in any other pane and tmux's copy mode never shows;
* the few that only exist server-wide (``_server_options``) are ones that
  don't change what the user's other sessions look like: zero escape-time
  (ESC reaches Claude at once), extended keys, and a ``terminal-features``
  entry in a fixed slot of our own so re-applying never grows the list;
* nothing ``-g``, and no ``-f``: the user's ``~/.tmux.conf`` loads as it
  always does when turbokod happens to be what starts the server;
* the client runs under ``env -u TMUX`` so a ``tk-tui`` started inside the
  user's tmux doesn't trip tmux's nesting guard.

The socket is passed explicitly (``-S``, resolved the way tmux resolves its
default) because ``capture_command`` hands children an allowlisted
environment. The test suites point ``TMUX_TMPDIR`` at their scratch
``$HOME``, which is what keeps them off the user's server.

**tmux is the record of which pane belongs to which project.** Each
session carries two user options, ``@tk_project`` (the canonical project
root) and ``@tk_cmd`` (the startup command, ``claude`` for a Claude pane),
and ``tmux_project_sessions`` reads them back with ``list-sessions``. There
is no separate file to drift out of sync: a session the user killed is
simply gone, and one created by a window that crashed is still found.
"""

from std.collections.list import List

from std.ffi import external_call

from .file_io import stat_file
from .lsp import capture_command
from .posix import exit_code_from_status, getenv_value, which
from .string_utils import shell_single_quote


comptime _OPT_PROJECT = String("@tk_project")
comptime _OPT_CMD = String("@tk_cmd")
comptime _OPT_RUN = String("@tk_run")
comptime _OPT_TESTS = String("@tk_tests")

comptime TESTS_RUN_TARGET = String("tests")
"""A test run's ``run_target``: its title, kind and exit line say
"tests". Which panes run tests is ``@tk_tests``, not this name, so a
project target called ``tests`` stays a target."""


@fieldwise_init
struct TmuxSessionInfo(Copyable, Movable):
    """One of turbokod's tmux sessions, as ``list-sessions`` reports it."""
    var name: String
    var project: String
    var startup_command: String
    var run_target: String
    """The project target this session runs (``@tk_run``), "" for a
    terminal."""
    var tests: Bool
    """The session runs the project's tests (``@tk_tests``)."""


def tmux_binary() -> String:
    """Absolute path of ``tmux`` on ``$PATH``, or "" when it isn't
    installed (the panes then fall back to a plain shell)."""
    return which(String("tmux"))


def tmux_socket_path() -> String:
    """The default server's socket, as tmux finds it:
    ``${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default``."""
    var dir = getenv_value(String("TMUX_TMPDIR"))
    if len(dir.as_bytes()) == 0:
        dir = String("/tmp")
    var uid = external_call["getuid", UInt32]()
    return dir + String("/tmux-") + String(Int(uid)) + String("/default")


def tmux_available() -> Bool:
    return len(tmux_binary().as_bytes()) > 0 \
        and len(tmux_socket_path().as_bytes()) > 0


def tmux_kind(
    startup_command: String, run_target: String, tests: Bool = False,
) -> String:
    """The ``<kind>`` half of a session name: ``tests`` for a test run,
    ``run-<target>`` for a run pane, ``shell`` for a bare prompt, else the
    startup command's first word."""
    if tests:
        return String("tests")
    if len(run_target.as_bytes()) > 0:
        return String("run-") + run_target
    if len(startup_command.as_bytes()) > 0:
        return String(startup_command.split(" ")[0])
    return String("shell")


def new_tmux_session_name(
    project: String, kind: String, taken: List[String],
) -> String:
    """A readable session name, for ``tmux attach -t`` over SSH:
    ``<project dir>-<kind>``, numbered from ``-2`` when that's in
    ``taken`` — ``turbokod-claude``, ``turbokod-shell``,
    ``turbokod-claude-2``, ``turbokod-run-server`` (``tmux_kind``). Only a
    label: the project a session
    belongs to is ``@tk_project``, so two projects with the same directory
    name can't mix up their panes."""
    var base = _name_part(_basename(project)) + String("-") + _name_part(kind)
    if base not in taken:
        return base
    var n = 2
    while (base + String("-") + String(n)) in taken:
        n += 1
    return base + String("-") + String(n)


def _basename(path: String) -> String:
    var b = path.as_bytes()
    var end = len(b)
    while end > 1 and b[end - 1] == 0x2F:
        end -= 1
    var start = end
    while start > 0 and b[start - 1] != 0x2F:
        start -= 1
    return String(StringSpan(unsafe_from_utf8=b[start:end]))


def _name_part(s: String) -> String:
    """``s`` safe in a tmux target: tmux forbids ``.`` and ``:`` in names
    and a shell is happier without spaces, so anything outside
    ``[A-Za-z0-9_-]`` becomes ``-``."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        var ok = (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x5A) \
            or (c >= 0x61 and c <= 0x7A) or c == 0x5F or c == 0x2D
        out.append(c if ok else UInt8(0x2D))
    if len(out) == 0:
        return String("x")
    return String(StringSpan(unsafe_from_utf8=Span(out)))


def _target(name: String) -> String:
    """``-t`` for session ``name`` and only it. A bare name falls back to
    the first session it starts, so with ``proj-shell`` gone, closing its
    pane killed ``proj-shell-2`` (or a ``proj-shell-dev`` of the user's)
    and re-attaching it attached that one. ``=`` asks for the exact name,
    and the ``:`` makes it a session for the commands that take a pane."""
    return String("=") + name + String(":")


def _base_argv(tmux: String, socket: String) -> List[String]:
    var argv = List[String]()
    argv.append(String("env"))
    argv.append(String("-u"))
    argv.append(String("TMUX"))
    argv.append(tmux)
    # UTF-8 regardless of the locale. A Dock launch has no ``LANG``, and
    # then tmux prints control characters in ``-F`` output as ``_`` — the
    # tabs ``_list_sessions`` splits on, so no session was ever found —
    # and draws a client's non-ASCII text as ``_`` too.
    argv.append(String("-u"))
    argv.append(String("-S"))
    argv.append(socket)
    return argv^


comptime _BASE_ARGC = 7
"""``len(_base_argv(...))`` — where the first command starts."""


def _cmd(mut argv: List[String], var words: List[String]):
    """Append one tmux command to a ``;``-separated sequence."""
    if len(argv) > _BASE_ARGC:
        argv.append(String(";"))
    for i in range(len(words)):
        argv.append(_literal(words[i]))


def _literal(word: String) -> String:
    """``word`` as one argument of a tmux command: tmux takes a ``;`` at
    the end of an argument as the end of the command (``make;`` was set
    as ``make``), and reads ``\\;`` there as a plain ``;``."""
    if word.endswith(String(";")):
        return String(word[byte = 0 : word.byte_length() - 1]) + String("\\;")
    return word


def _server_options(mut argv: List[String]):
    """The server-wide options turbokod needs. They change how keys reach
    programs, not what any session looks like, so the user's other
    sessions get them too without noticing."""
    _cmd(argv, [String("set"), String("-s"), String("escape-time"), String("0")])
    _cmd(argv, [String("set"), String("-s"), String("focus-events"), String("on")])
    _cmd(argv, [String("set"), String("-s"), String("extended-keys"), String("on")])
    _cmd(argv, [String("set"), String("-s"), String("set-clipboard"), String("on")])
    # The emulator (libghostty-vt) does truecolor and CSI-u keys; tell tmux
    # so it passes them through instead of downsampling. A fixed index, so
    # setting it on every attach replaces our entry instead of appending.
    _cmd(argv, [
        String("set"), String("-s"), String("terminal-features[247]"),
        String("xterm-256color:RGB:extkeys:clipboard:focus:title"),
    ])


def _session_options(mut argv: List[String], name: String):
    """What makes tmux invisible inside a pane — set on ``name`` only, so
    the user's own sessions keep their status line and prefix key."""
    _cmd(argv, [String("set"), String("-t"), _target(name), String("status"), String("off")])
    _cmd(argv, [String("set"), String("-t"), _target(name), String("prefix"), String("None")])
    _cmd(argv, [String("set"), String("-t"), _target(name), String("prefix2"), String("None")])
    _cmd(argv, [String("set"), String("-t"), _target(name), String("mouse"), String("on")])
    _cmd(argv, [
        String("set"), String("-w"), String("-t"), _target(name),
        String("allow-passthrough"), String("on"),
    ])
    _cmd(argv, [
        String("set"), String("-w"), String("-t"), _target(name),
        String("window-size"), String("latest"),
    ])


def tmux_attach_argv(
    tmux: String, socket: String, name: String, create: Bool,
    cwd: String, project: String, startup_command: String,
    cols: Int, rows: Int,
    run_target: String = String(""), env: List[String] = List[String](),
    tests: Bool = False,
) -> List[String]:
    """The client command line a pane runs on its pty.

    ``create`` makes the session first (in ``cwd``, tagged with the
    project and startup command) and then attaches. A terminal's startup
    command is typed into its shell. A run pane's (``run_target``) is run
    by the session's process (``_run_wrapper``), with ``env`` (``K=V``)
    in the session environment. Otherwise it attaches to the existing
    ``name``, and a session that has since died makes the client exit at
    once — the pane sees EOF, as for a shell that exited."""
    var argv = _base_argv(tmux, socket)
    _server_options(argv)
    if create:
        var nw = List[String]()
        nw.append(String("new-session"))
        nw.append(String("-d"))
        nw.append(String("-s"))
        nw.append(name)
        nw.append(String("-x"))
        nw.append(String(cols))
        nw.append(String("-y"))
        nw.append(String(rows))
        nw.append(String("-e"))
        nw.append(String("COLORTERM=truecolor"))
        if not _has_locale():
            # Started from the Dock: the shell would get no locale and
            # mangle non-ASCII. A terminal launch passes its own along.
            nw.append(String("-e"))
            nw.append(String("LANG=en_US.UTF-8"))
        if len(cwd.as_bytes()) > 0:
            nw.append(String("-c"))
            nw.append(cwd)
        var is_run = len(run_target.as_bytes()) > 0
        if is_run:
            for i in range(len(env)):
                nw.append(String("-e"))
                nw.append(env[i])
            nw.append(String("--"))
            nw.append(String("/bin/sh"))
            nw.append(String("-c"))
            nw.append(_run_wrapper(startup_command, run_target))
        _cmd(argv, nw^)
        if is_run:
            _cmd(argv, [
                String("set-option"), String("-t"), _target(name), _OPT_RUN, run_target,
            ])
        if tests:
            _cmd(argv, [
                String("set-option"), String("-t"), _target(name), _OPT_TESTS, String("1"),
            ])
        _cmd(argv, [
            String("set-option"), String("-t"), _target(name), _OPT_PROJECT, project,
        ])
        _cmd(argv, [
            String("set-option"), String("-t"), _target(name), _OPT_CMD, startup_command,
        ])
        if not is_run and len(startup_command.as_bytes()) > 0:
            # Typed, not exec'd: the user's rc files run first, and the
            # prompt comes back when the command exits.
            _cmd(argv, [
                String("send-keys"), String("-t"), _target(name), String("-l"),
                startup_command,
            ])
            _cmd(argv, [
                String("send-keys"), String("-t"), _target(name), String("Enter"),
            ])
    # A session that's gone fails here, which ends the sequence: the
    # client exits and the pane sees EOF.
    _session_options(argv, name)
    _cmd(argv, [String("attach-session"), String("-t"), _target(name)])
    return argv^


def _has_locale() -> Bool:
    return len(getenv_value(String("LC_ALL")).as_bytes()) > 0 \
        or len(getenv_value(String("LC_CTYPE")).as_bytes()) > 0 \
        or len(getenv_value(String("LANG")).as_bytes()) > 0


def run_exit_line(target: String) -> String:
    """The start of the line a run pane prints when its command exits:
    ``[<target> exited with <status>]``. ``TerminalPane`` watches its grid
    for it."""
    return String("[") + target + String(" exited with ")


def _run_wrapper(command: String, target: String) -> String:
    """The ``sh -c`` script around a run target's ``command``.

    It prints ``run_exit_line`` itself and then idles, rather than letting
    the pane die under tmux's ``remain-on-exit``: tmux paints its
    dead-pane line after a linefeed on the bottom row, which scrolls the
    top row of the output out of view — the whole output, for a
    one-liner. Idling keeps the session (and the output) until Restart
    (``respawn-pane -k``) or the pane's close.

    ``trap : INT`` makes Ctrl-C — Stop — end the command but not the
    script, so the exit line still prints; the command gets the default
    disposition back as it starts. After it, ``stty -echo -isig`` keeps
    keys typed into the finished pane from echoing or killing the idler."""
    return String("trap : INT; ") + command \
        + String("; s=$?; printf '\\n[%s exited with %s]\\n' ") \
        + shell_single_quote(target) \
        + String(" \"$s\"; stty -echo -isig 2>/dev/null; exec tail -f /dev/null")


def tmux_respawn(name: String):
    """Kill whatever runs in ``name``'s pane and start its command again,
    in the same session — a run pane's Restart."""
    _simple(String("respawn-pane"), name, List[String]([String("-k")]))


def tmux_stop(name: String):
    """Ctrl-C into ``name``'s pane — a run pane's Stop. The command ends
    the way it would in a terminal; the pane stays with its output and
    the exit line (see ``_run_wrapper``)."""
    _simple(
        String("send-keys"), name, List[String](),
        List[String]([String("C-c")]),
    )


def _simple(
    verb: String, name: String, var flags: List[String],
    var trailing: List[String] = List[String](),
):
    var tmux = tmux_binary()
    var socket = tmux_socket_path()
    if len(tmux.as_bytes()) == 0 or len(name.as_bytes()) == 0:
        return
    var argv = _base_argv(tmux, socket)
    var words = List[String]()
    words.append(verb)
    for i in range(len(flags)):
        words.append(flags[i])
    words.append(String("-t"))
    words.append(_target(name))
    for i in range(len(trailing)):
        words.append(trailing[i])
    _cmd(argv, words^)
    try:
        _ = capture_command(argv)
    except:
        pass


def _query(name: String, var words: List[String]) -> String:
    """Run one tmux command against session ``name`` (``-t`` going right
    after the verb, ahead of any positional argument such as a format) and
    return its stdout, "" on any failure."""
    var tmux = tmux_binary()
    var socket = tmux_socket_path()
    if len(tmux.as_bytes()) == 0 or len(name.as_bytes()) == 0:
        return String("")
    var argv = _base_argv(tmux, socket)
    words.insert(1, _target(name))
    words.insert(1, String("-t"))
    _cmd(argv, words^)
    try:
        var r = capture_command(argv)
        if exit_code_from_status(Int(r.status)) != 0:
            return String("")
        return r.stdout
    except:
        return String("")


@fieldwise_init
struct TmuxPaneState(Copyable, Movable):
    """What a pane can't read off its own grid, because tmux sits between:
    whether the program asked for mouse reports (tmux itself always tracks
    the mouse, ``mouse on``), whether it has the alternate screen up, and
    how many rows of history tmux holds."""
    var wants_mouse: Bool
    var alternate: Bool
    var history_rows: Int


def tmux_pane_state(name: String) -> TmuxPaneState:
    var out = _query(name, [
        String("display-message"), String("-p"),
        String("#{mouse_any_flag}#{alternate_on}#{history_size}"),
    ])
    var b = out.as_bytes()
    if len(b) < 3:
        return TmuxPaneState(False, False, 0)
    var rows = 0
    for i in range(2, len(b)):
        if b[i] < 0x30 or b[i] > 0x39:
            break
        rows = rows * 10 + Int(b[i] - 0x30)
    return TmuxPaneState(b[0] == 0x31, b[1] == 0x31, rows)


def tmux_history(name: String, max_lines: Int) -> String:
    """``name``'s pane — up to ``max_lines`` of history plus the screen —
    as terminal output (colors kept, rows ended by CR LF), ready to feed a
    ``Vt`` of the pane's size: its bottom rows are then the screen and the
    rest its scrollback. This is how a pane scrolls without tmux's copy
    mode (and the position indicator it draws)."""
    var out = _query(name, [
        String("capture-pane"), String("-p"), String("-e"),
        String("-S"), String("-") + String(max_lines),
    ])
    var b = out.as_bytes()
    var end = len(b)
    if end > 0 and b[end - 1] == 0x0A:
        end -= 1
    var res = String("\x1b[0m")
    var start = 0
    for i in range(end):
        if b[i] == 0x0A:
            res += String(StringSpan(unsafe_from_utf8=b[start:i]))
            res += String("\r\n")
            start = i + 1
    res += String(StringSpan(unsafe_from_utf8=b[start:end]))
    return res^


def prepare_tmux_socket_dir(socket: String):
    """tmux creates the socket but not, with ``-S``, its directory — and a
    bare ``tmux`` refuses a ``tmux-<uid>`` directory anyone else can read,
    so it's made ``0700`` like tmux makes it."""
    var b = socket.as_bytes()
    var end = len(b)
    while end > 0 and b[end - 1] != 0x2F:
        end -= 1
    if end <= 1:
        return
    var dir = String(StringSpan(unsafe_from_utf8=b[0:end - 1]))
    var c_dir = dir + String("\0")
    _ = external_call["mkdir", Int32](c_dir.unsafe_ptr(), Int32(0o700))


def tmux_kill_session(name: String):
    """End ``name`` and everything running in it. Best effort: a session
    that's already gone is the outcome we wanted anyway."""
    _simple(String("kill-session"), name, List[String]())


def tmux_session_names() -> List[String]:
    """Every session on the server, for ``new_tmux_session_name`` to steer
    clear of. Empty when no server is running."""
    var out = List[String]()
    var rows = _list_sessions()
    for i in range(len(rows)):
        out.append(rows[i].name)
    return out^


def tmux_project_sessions(project: String) -> List[TmuxSessionInfo]:
    """turbokod's live sessions for ``project``, oldest first, so a
    restart re-stacks the panes in the order they were opened.

    No socket file means no server, and then nothing is spawned — which
    is what keeps the many ``open_project`` calls in the test suites (each
    with a scratch ``$HOME``) from running tmux at all."""
    var out = List[TmuxSessionInfo]()
    if len(project.as_bytes()) == 0:
        return out^
    var rows = _list_sessions()
    for i in range(len(rows)):
        if rows[i].info.project == project:
            out.append(rows[i].info.copy())
    return out^


@fieldwise_init
struct _SessionRow(Copyable, Movable):
    var name: String
    var created: Int
    var info: TmuxSessionInfo


def _list_sessions() -> List[_SessionRow]:
    """Every session, oldest first (``session_created`` is in seconds, so
    ties fall back to the name)."""
    var out = List[_SessionRow]()
    var tmux = tmux_binary()
    var socket = tmux_socket_path()
    if len(tmux.as_bytes()) == 0 or len(socket.as_bytes()) == 0:
        return out^
    if not stat_file(socket).ok:
        return out^
    var argv = _base_argv(tmux, socket)
    _cmd(argv, [
        String("list-sessions"), String("-F"),
        String("#{session_name}\t#{session_created}\t#{") + _OPT_PROJECT
        + String("}\t#{") + _OPT_CMD + String("}\t#{") + _OPT_RUN
        + String("}\t#{") + _OPT_TESTS + String("}"),
    ])
    var res: String
    try:
        var r = capture_command(argv)
        if exit_code_from_status(Int(r.status)) != 0:
            # "no server running" on a stale socket.
            return out^
        res = r.stdout
    except:
        return out^
    var lines = res.split("\n")
    for i in range(len(lines)):
        var fields = String(lines[i]).split("\t")
        if len(fields) < 6:
            continue
        var name = String(fields[0])
        var created = 0
        try:
            created = Int(String(fields[1]))
        except:
            pass
        out.append(_SessionRow(
            name, created,
            TmuxSessionInfo(
                name, String(fields[2]), String(fields[3]), String(fields[4]),
                String(fields[5]) == String("1"),
            ),
        ))
    # Insertion sort — a handful of sessions.
    for i in range(1, len(out)):
        var j = i
        while j > 0 and _row_less(out[j], out[j - 1]):
            var t = out[j].copy()
            out[j] = out[j - 1].copy()
            out[j - 1] = t^
            j -= 1
    return out^


def _row_less(a: _SessionRow, b: _SessionRow) -> Bool:
    if a.created != b.created:
        return a.created < b.created
    return a.name < b.name
