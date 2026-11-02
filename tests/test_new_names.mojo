"""``new_names``: the distinct functions, variables and types a changeset
introduces, for Review ▸ new names."""

from std.collections.optional import Optional
from std.testing import TestSuite, assert_equal, assert_true
from turbokod.canvas import Canvas
from turbokod.desktop import Desktop
from turbokod.file_io import join_path, write_file
from turbokod.geometry import Rect
from turbokod.new_names import NewName, new_names_in
from turbokod.review_mode import ReviewMode
from turbokod.ui_grid import UIEvent, ui_act, ui_set
from support import (
    _ensure_dir, _rm_rf, _run_git, _temp_path, setup_test_env, string_list,
)


def _names(path: String, before: String, after: String) -> List[NewName]:
    var paths = List[String]()
    paths.append(path)
    var befores = List[String]()
    befores.append(before)
    var afters = List[String]()
    afters.append(after)
    return new_names_in(paths, befores, afters)


def _summary(names: List[NewName]) -> String:
    """``kind name`` per new name, comma-separated."""
    var s = String("")
    for i in range(len(names)):
        if i > 0:
            s += ", "
        s += names[i].what + " " + names[i].name
    return s^


def test_python_function_params_and_locals() raises:
    var before = String("def old():\n    return 1\n")
    var after = String(
        "def old():\n    return 1\n\n"
        "def fresh(self, count: int, label='x'):\n"
        "    total = count + 1\n"
        "    for item in range(total):\n"
        "        print(item, sep='')\n"
        "    return old()\n"
    )
    var names = _names(String("a.py"), before, after)
    assert_equal(
        _summary(names),
        String(
            "function fresh, parameter count, parameter label,"
            " variable total, variable item"
        ),
    )
    assert_equal(names[0].row, 3)
    assert_equal(names[0].col, 4)


def test_only_added_rows_and_names_not_in_before() raises:
    """A name the before side already mentions isn't new, and a definition
    on an unchanged row isn't reported."""
    var before = String("x = 1\nprint(helper)\n")
    var after = String("x = 1\nprint(helper)\nhelper = 2\ny = 3\ny = 4\n")
    assert_equal(_summary(_names(String("m.py"), before, after)), String("variable y"))


def test_names_are_distinct_across_files() raises:
    var paths = List[String]()
    paths.append(String("a.mojo"))
    paths.append(String("b.mojo"))
    var befores = List[String]()
    befores.append(String(""))
    befores.append(String("def moved():\n    pass\n"))
    var afters = List[String]()
    afters.append(String("def moved():\n    pass\n\nstruct Thing:\n    var size: Int\n"))
    afters.append(String("def other():\n    var size = 2\n"))
    var names = new_names_in(paths, befores, afters)
    assert_equal(
        _summary(names), String("struct Thing, variable size, function other"),
    )
    assert_equal(names[2].file, 1)


def test_multiline_params_and_modifiers() raises:
    var after = String(
        "def build(\n"
        "    mut self, var root: String,\n"
        "    paths: List[String],\n"
        ") -> Int:\n"
        "    return 0\n"
    )
    assert_equal(
        _summary(_names(String("x.mojo"), String(""), after)),
        String("function build, parameter root, parameter paths"),
    )


def test_comments_and_strings_are_skipped() raises:
    var after = String(
        "# def commented():\n"
        "s = 'let quoted = 1'\n"
        '"""\nclass InDocstring:\n"""\n'
        "fn real() {}\n"
    )
    assert_equal(
        _summary(_names(String("x.rs"), String(""), after)),
        String("variable s, function real"),
    )


def test_js_arrow_and_keyword_args() raises:
    var after = String(
        "const handler = (ev) => ev.x;\n"
        "let count = 0;\n"
        "call(\n"
        "    option=1,\n"
        ")\n"
    )
    assert_equal(
        _summary(_names(String("x.ts"), String(""), after)),
        String("function handler, variable count"),
    )


def test_c_like_declarations() raises:
    var after = String(
        "static int compute(int width, char *name) {\n"
        "    int total = width;\n"
        "    return total;\n"
        "}\n"
    )
    assert_equal(
        _summary(_names(String("x.c"), String(""), after)),
        String(
            "function compute, parameter width, parameter name, variable total"
        ),
    )


def test_review_mode_new_names_finds_names_across_files() raises:
    var rv = ReviewMode()
    var paths = List[String]()
    paths.append(String("a.py"))
    paths.append(String("b.py"))
    var befores = List[String]()
    befores.append(String("x = 1\n"))
    befores.append(String(""))
    var afters = List[String]()
    afters.append(String("x = 1\ndef alpha():\n    pass\n"))
    afters.append(String("beta = 2\n"))
    rv.build_from_pairs(paths, befores, afters)
    var names = rv.new_names()
    assert_equal(len(names), 2)
    assert_equal(names[0].what, String("function"))
    assert_equal(names[1].name, String("beta"))
    assert_equal(names[1].file, 1)


def test_desktop_names_review_changesets_names_and_context() raises:
    """Review new names is one dialog: the changesets on top (the unstaged
    changes, then the commits), the selected one's new names — name / kind
    / file — and the selected name's file in a code view with its line
    marked. Moving to another changeset reloads the names; Open jumps to
    the definition, and reopening comes back to the same place."""
    var dir = _temp_path(String("_review_names"))
    _rm_rf(dir)
    _ensure_dir(dir)
    if _run_git(dir, string_list(String("init"), String("-q"))) != 0:
        _rm_rf(dir)
        return
    _ = _run_git(dir, string_list(
        String("config"), String("user.email"), String("test@example.com"),
    ))
    _ = _run_git(dir, string_list(String("config"), String("user.name"), String("T")))
    var path = join_path(dir, String("m.py"))
    assert_true(write_file(path, String("x = 1\n")))
    _ = _run_git(dir, string_list(String("add"), String(".")))
    _ = _run_git(dir, string_list(String("commit"), String("-qm"), String("one")))
    assert_true(write_file(path, String("x = 1\nlimit = 5\n")))
    _ = _run_git(dir, string_list(String("commit"), String("-qam"), String("two")))
    assert_true(write_file(
        path, String("x = 1\nlimit = 5\n\ndef grow(amount):\n    return x + amount\n"),
    ))
    var d = Desktop()
    d.project = Optional[String](dir)
    _ = d.dispatch_action(String("git:review-names"), Rect(0, 0, 100, 30))
    assert_equal(d.ui_surface(), String("names_review"))
    var tree = d.ui_tree(String("names_review"))
    ref changes = tree.children[0].children[0]
    assert_equal(len(changes.rows), 3)
    assert_equal(changes.rows[0][0], String("Unstaged changes"))
    assert_equal(changes.rows[1][1], String("two"))
    assert_equal(changes.number, 0)
    ref table = tree.children[0].children[1]
    assert_equal(len(table.rows), 2)
    assert_equal(table.rows[0][0], String("grow"))
    assert_equal(table.rows[0][1], String("function"))
    assert_equal(table.rows[0][2], String("m.py:4"))
    assert_equal(table.rows[1][1], String("parameter"))
    ref code = tree.children[0].children[2]
    assert_equal(code.count, 5)
    assert_equal(code.number, 3)
    # The grid projector draws it.
    var canvas = Canvas(100, 30)
    d.paint(canvas, Rect(0, 0, 100, 30))
    # Commit "two": its one new name.
    var events = List[UIEvent]()
    events.append(ui_set(String("changes"), String("1")))
    _ = d.ui_apply(String("names_review"), events)
    tree = d.ui_tree(String("names_review"))
    assert_equal(len(tree.children[0].children[1].rows), 1)
    assert_equal(tree.children[0].children[1].rows[0][0], String("limit"))
    d.paint(canvas, Rect(0, 0, 100, 30))
    # Back to the unstaged changes; open the parameter.
    events = List[UIEvent]()
    events.append(ui_set(String("changes"), String("0")))
    events.append(ui_set(String("names"), String("1")))
    events.append(ui_act(String("open")))
    _ = d.ui_apply(String("names_review"), events)
    assert_true(not d.names_review.active)
    ref ed = d.windows.windows[d.windows.focused].editor
    assert_equal(ed.file_path, path)
    assert_equal(ed.selections[0].row, 3)
    assert_equal(ed.selections[0].col, 9)
    # Reopening resumes on the same changeset and name.
    _ = d.dispatch_action(String("git:review-names"), Rect(0, 0, 100, 30))
    assert_equal(d.names_review.change, 0)
    assert_equal(d.names_review.selected, 1)
    d.shutdown()
    _rm_rf(dir)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
