"""Search fields reopen with the project's previous text, fully selected:
Find / Replace, Find / Replace in Project, Quick Open, Find Symbol.

Shared fixtures live in ``tests/support.mojo`` and
``scripts/run_tests.sh`` runs every suite.
"""

from std.testing import TestSuite, assert_equal, assert_true
from turbokod.desktop import Desktop
from turbokod.file_io import join_path
from turbokod.find_symbol import FindSymbol
from turbokod.project_find import ProjectFind
from turbokod.query_memory import QueryMemory
from turbokod.text_field import TextField

from support import _ensure_dir, _test_home, setup_test_env


def _assert_all_selected(f: TextField) raises:
    assert_equal(f.anchor, 0)
    assert_equal(f.cursor, len(f.text.as_bytes()))


def test_query_memory_is_per_root() raises:
    var m = QueryMemory()
    assert_equal(m.get(String("/a")), String(""))
    m.put(String("/a"), String("one"))
    m.put(String("/b"), String("two"))
    m.put(String("/a"), String("three"))
    assert_equal(m.get(String("/a")), String("three"))
    assert_equal(m.get(String("/b")), String("two"))
    assert_equal(m.get(String("")), String(""))


def test_find_symbol_reopens_with_the_projects_previous_query() raises:
    var fs = FindSymbol()
    fs.open(String("/nonexistent-a"))
    fs.query.set_text(String("Widget"))
    fs.close()
    fs.open(String("/nonexistent-b"))
    assert_equal(fs.query.text, String(""))
    fs.query.set_text(String("Gadget"))
    fs.close()
    fs.open(String("/nonexistent-a"))
    assert_equal(fs.query.text, String("Widget"))
    _assert_all_selected(fs.query)
    fs.close()
    # A selection seed still wins over the remembered query.
    fs.open(String("/nonexistent-b"), String("Other"), select_prefill=True)
    assert_equal(fs.query.text, String("Other"))
    fs.close()


def test_project_find_reopens_with_the_projects_previous_query() raises:
    var pf = ProjectFind()
    pf.open(String("/nonexistent-a"))
    pf.query.set_text(String("needle"))
    pf.close()
    pf.open_replace(String("/nonexistent-b"))
    assert_equal(pf.query.text, String(""))
    pf.query.set_text(String("pin"))
    pf.close()
    # Back in the first project: its query, selected, and searched again.
    pf.open(String("/nonexistent-a"))
    assert_equal(pf.query.text, String("needle"))
    _assert_all_selected(pf.query)
    assert_true(pf.searching())
    pf.close()
    # Same project again resumes, still selected.
    pf.open_replace(String("/nonexistent-a"))
    assert_equal(pf.query.text, String("needle"))
    _assert_all_selected(pf.query)
    pf.close()


def test_find_needle_is_per_project() raises:
    var a = join_path(_test_home(), String("search_memory_a"))
    var b = join_path(_test_home(), String("search_memory_b"))
    _ensure_dir(a)
    _ensure_dir(b)
    var d = Desktop()
    d._set_project(a)
    d._last_search = String("alpha")
    d._set_project(b)
    assert_equal(d._last_search, String(""))
    d._last_search = String("beta")
    d._set_project(a)
    assert_equal(d._last_search, String("alpha"))
    d.close_project()
    assert_equal(d._last_search, String(""))
    d._set_project(b)
    assert_equal(d._last_search, String("beta"))
    # Find and Replace both reopen with it, fully selected.
    d._open_find_prompt()
    assert_equal(d.prompt.input.text, String("beta"))
    _assert_all_selected(d.prompt.input)
    d.prompt.close()
    d._open_replace_prompt()
    assert_equal(d.prompt.input.text, String("beta"))
    _assert_all_selected(d.prompt.input)
    d.prompt.close()
    d.shutdown()


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
