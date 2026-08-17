"""Shared fixtures for the test suites in this directory.

The suite used to be one 23k-line ``test_basic.mojo``, which had grown into
a multi-hour ``mojo build``. It is now one file per topic, each its own
entry point with its own ``main()``; ``scripts/run_tests.sh`` builds them in
parallel and runs them one at a time. Fixtures used by more than one suite
live here — anything used by a single suite stays in that suite's file.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_true
from turbokod.desktop import Desktop
from turbokod.file_io import basename
from turbokod.git_blame import BlameLine
from turbokod.menu import Menu, MenuItem
from turbokod.project_targets import ProjectTargets
from turbokod.project_settings import ProjectSettings
from turbokod.text_view import VisualLine
from turbokod.lsp import capture_command
from turbokod.highlight import Highlight
from turbokod.spell import Speller
from turbokod.project_grammars import GrammarOverride
from turbokod.config import OnSaveAction, save_config
from turbokod.events import Event, MOD_NONE
from turbokod.geometry import Point, Rect


comptime _SCREEN = Rect(0, 0, 100, 30)


comptime _VIEW = Rect(0, 0, 80, 24)


def _assert_layout_contiguous(line: String, layout: List[VisualLine]) raises:
    """Every byte of ``line`` belongs to exactly one segment, in order:
    first segment starts at byte 0, each starts where the previous ended,
    the last ends at the line length. This is the invariant the editor's
    caret / selection / mouse mapping depends on."""
    var n = len(line.as_bytes())
    assert_equal(len(layout) >= 1, True)
    assert_equal(layout[0].byte_start, 0)
    for i in range(len(layout)):
        if i > 0:
            assert_equal(layout[i].byte_start, layout[i - 1].byte_end)
        assert_true(layout[i].byte_end >= layout[i].byte_start)
    assert_equal(layout[len(layout) - 1].byte_end, n)


def _contains(s: String, sub: String) -> Bool:
    var sb = s.as_bytes()
    var nb = sub.as_bytes()
    var n = len(nb)
    var h = len(sb)
    if n == 0:
        return True
    if n > h:
        return False
    for i in range(h - n + 1):
        var hit = True
        for k in range(n):
            if sb[i + k] != nb[k]:
                hit = False
                break
        if hit:
            return True
    return False


def _doc_paths(d: Desktop) -> List[String]:
    """Basenames of the file-backed editor windows currently open, in
    window order. Test helper for the window-cap assertions."""
    var out = List[String]()
    for i in range(len(d.windows.windows)):
        if d.windows.windows[i].is_editor \
                and len(d.windows.windows[i].editor.file_path.as_bytes()) > 0:
            out.append(basename(d.windows.windows[i].editor.file_path))
    return out^


def _docs_contains(d: Desktop, name: String) -> Bool:
    var paths = _doc_paths(d)
    for i in range(len(paths)):
        if paths[i] == name:
            return True
    return False


def _blame(short_sha: String, author: String) -> BlameLine:
    """A ``BlameLine`` carrying just what the gutter paints. The commit
    metadata the detail popup shows (full sha, mail, time, summary) is left
    empty — tests that need it fill the fields in directly."""
    var bl = BlameLine()
    bl.commit = short_sha
    bl.author = author
    return bl^


def _empty_menu(label: String) -> Menu:
    return Menu(label, List[MenuItem]())


def _ensure_dir(path: String) raises:
    var argv = List[String]()
    argv.append(String("mkdir"))
    argv.append(String("-p"))
    argv.append(path)
    _ = capture_command(argv)


def _hl_lines(*texts: String) -> List[String]:
    var out = List[String]()
    for t in texts:
        out.append(String(t))
    return out^


def _hl_set(hls: List[Highlight]) -> List[Highlight]:
    """Sort-of-canonicalize a Highlight list: sort by (row, col_start,
    col_end). Two passes that agree should produce equal lists post-sort
    even if they emit highlights in slightly different orders."""
    var sorted = List[Highlight]()
    for i in range(len(hls)):
        sorted.append(hls[i])
    # Insertion sort — lists are small (a few thousand entries) and we
    # don't want to pull in a generic sort dependency.
    for i in range(1, len(sorted)):
        var j = i
        while j > 0:
            var a = sorted[j - 1]
            var b = sorted[j]
            var swap = False
            if a.row > b.row:
                swap = True
            elif a.row == b.row:
                if a.col_start > b.col_start:
                    swap = True
                elif a.col_start == b.col_start and a.col_end > b.col_end:
                    swap = True
            if not swap:
                break
            sorted[j - 1] = b
            sorted[j] = a
            j -= 1
    return sorted^


def _key(k: UInt32, mods: UInt8 = MOD_NONE) -> Event:
    return Event.key_event(k, mods)


def _ps_open(
    var lib: List[OnSaveAction], var pa: List[OnSaveAction],
) -> ProjectSettings:
    """Open a ProjectSettings view on an in-memory on-save library +
    project-enabled set (no disk). The project root is a dummy — these
    unit tests assert on the in-memory working state, not persistence."""
    var ps = ProjectSettings()
    ps.open(
        String("/tmp/turbokod_ps_unit"), ProjectTargets(),
        List[GrammarOverride](), lib^, pa^,
    )
    return ps^


def _rm_rf(path: String) raises:
    var argv = List[String]()
    argv.append(String("rm"))
    argv.append(String("-rf"))
    argv.append(path)
    _ = capture_command(argv)


def _run_git(root: String, var args: List[String]) raises -> Int:
    """Wrapper around ``capture_command`` for the staging integration
    test below. Returns the exit status. We rebuild the argv with
    ``git -C <root>`` in front so the test doesn't have to repeat it."""
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(root)
    for i in range(len(args)):
        argv.append(args[i])
    var r = capture_command(argv)
    return Int(r.status)


def _spell_with_dict(words: List[String]) -> Speller:
    """Build a Speller seeded with an explicit small dictionary so the
    tests don't depend on whichever ``/usr/share/dict/words`` happens to
    ship with the host."""
    var s = Speller()
    s.load_words(words)
    return s^


def _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def _temp_path(suffix: String) -> String:
    """Cheap unique path under /tmp; pid+suffix is enough for our serial test
    suite (no parallelism)."""
    var pid = external_call["getpid", Int32]()
    return String("/tmp/turbokod_test_") + String(Int(pid)) + suffix


def setup_test_env():
    """Point $HOME at a scratch dir and stub the clipboard.

    Every suite calls this first. Tests that build a ``Desktop`` write
    ``~/.config/turbokod/config.json`` via ``_set_project`` → ``save_config``,
    and grammar installs / dir-browser lookups also resolve $HOME — without
    the redirect a test run clobbers the developer's real config. The
    clipboard stub keeps cut/copy tests off the system pasteboard.

    The scratch $HOME is a fixed path (not per-pid): a couple of tests write
    into it directly and then read it back through the config loader, so the
    two have to agree. That's also why suites are run one at a time rather
    than concurrently — see scripts/run_tests.sh.
    """
    var test_home = String("/tmp/turbokod_test_home")
    var c_home_dir = test_home + String("\0")
    _ = external_call["mkdir", Int32](c_home_dir.unsafe_ptr(), Int32(0o755))
    var c_name = String("HOME\0")
    var c_value = test_home + String("\0")
    _ = external_call["setenv", Int32](
        c_name.unsafe_ptr(), c_value.unsafe_ptr(), Int32(1),
    )
    var c_fake = String("TURBOKOD_FAKE_CLIPBOARD\0")
    var c_one = String("1\0")
    _ = external_call["setenv", Int32](
        c_fake.unsafe_ptr(), c_one.unsafe_ptr(), Int32(1),
    )
