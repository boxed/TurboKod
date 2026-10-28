"""Reading ``.editorconfig`` files: what a save trims, which line endings it
writes and whether it adds a final newline all come from here."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.editorconfig import EditorConfig, load_editorconfig_for_path, parse_editorconfig
from turbokod.file_io import write_file
from support import _ensure_dir, _rm_rf, _temp_path, setup_test_env


def _sections(text: String) -> String:
    """``pattern: key=value, ...`` per section, ``|``-joined."""
    var f = parse_editorconfig(String("/x"), text)
    var out = String("")
    for s in range(len(f.sections)):
        if s > 0:
            out += "|"
        out += f.sections[s].pattern + ":"
        for k in range(len(f.sections[s].keys)):
            out += " " + f.sections[s].keys[k] + "=" + f.sections[s].values[k]
    return out^


def test_the_first_line_counts() raises:
    assert_true(parse_editorconfig("/x", "root=true").is_root)
    assert_equal(_sections("[*]\nindent_size = 2"), "*: indent_size=2")


def test_comments_and_blank_lines_are_skipped() raises:
    assert_equal(
        _sections("[*]\n# a = 1\n  ; b = 2\n\n   \nc = 3\n"),
        "*: c=3",
    )
    assert_false(parse_editorconfig("/x", "# root = true\n").is_root)
    assert_false(parse_editorconfig("/x", "; root = true\n").is_root)


def test_crlf_files_read_like_lf_files() raises:
    var f = parse_editorconfig("/x", "root = true\r\n[*.md]\r\ntrim_trailing_whitespace = false\r\n")
    assert_true(f.is_root)
    assert_equal(_sections("root = true\r\n[*.md]\r\ntrim_trailing_whitespace = false\r\n"),
        "*.md: trim_trailing_whitespace=false")


def test_a_header_needs_its_closing_bracket() raises:
    assert_equal(_sections("[*.py\na = 1\n[*.c]\nb = 2\n"), "*.c: b=2")
    assert_equal(_sections("[\na = 1\n"), "")
    assert_equal(_sections("[]\na = 1\n"), ": a=1")
    # the last bracket closes it
    assert_equal(_sections("[*.[ch]]\na = 1\n"), "*.[ch]: a=1")


def test_a_value_may_hold_an_equals_sign() raises:
    assert_equal(_sections("[*]\n key  =  a = b \nnot a pair\n"), "*: key=a = b")


def test_settings_before_any_section_only_say_root() raises:
    var f = parse_editorconfig("/x", "indent_size = 2\nROOT = True\n[*]\n")
    assert_true(f.is_root)
    assert_equal(len(f.sections), 1)
    assert_equal(len(f.sections[0].keys), 0)
    assert_false(parse_editorconfig("/x", "root = false\n").is_root)
    assert_false(parse_editorconfig("/x", "[*]\nroot = true\n").is_root)


def _config(*pairs: String) -> EditorConfig:
    var c = EditorConfig()
    var i = 0
    while i + 1 < len(pairs):
        c._set(pairs[i], pairs[i + 1])
        i += 2
    return c^


def test_unset_takes_a_setting_back() raises:
    # e.g. ``[*]`` trims trailing whitespace, ``[*.md]`` unsets it: in
    # markdown two trailing spaces are a line break
    var c = _config(
        "indent_style", "tab", "indent_size", "2", "tab_width", "8",
        "end_of_line", "crlf", "charset", "utf-8",
        "trim_trailing_whitespace", "true", "insert_final_newline", "false",
        "max_line_length", "100",
    )
    var keys: List[String] = [
        "indent_style", "indent_size", "tab_width", "end_of_line", "charset",
        "trim_trailing_whitespace", "insert_final_newline", "max_line_length",
    ]
    for k in keys:
        c._set(k, " UNSET ")
    var d = EditorConfig()
    assert_equal(c.indent_style, d.indent_style)
    assert_equal(c.indent_size, d.indent_size)
    assert_equal(c.tab_width, d.tab_width)
    assert_equal(c.end_of_line, d.end_of_line)
    assert_equal(c.charset, d.charset)
    assert_equal(c.trim_trailing_whitespace, d.trim_trailing_whitespace)
    assert_equal(c.insert_final_newline, d.insert_final_newline)
    assert_equal(c.max_line_length, d.max_line_length)


def test_values_that_mean_nothing_leave_the_setting_alone() raises:
    var c = _config(
        "indent_style", "space", "indent_size", "2", "tab_width", "8",
        "end_of_line", "lf", "trim_trailing_whitespace", "true",
        "insert_final_newline", "true", "max_line_length", "100",
    )
    for k in ["indent_style", "indent_size", "tab_width", "end_of_line",
              "trim_trailing_whitespace", "insert_final_newline", "max_line_length"]:
        c._set(String(k), "bogus")
        c._set(String(k), "0")
    assert_equal(c.indent_style, "space")
    assert_equal(c.indent_size, 2)
    assert_equal(c.tab_width, 8)
    assert_equal(c.end_of_line, "lf")
    assert_equal(c.trim_trailing_whitespace, 1)
    assert_equal(c.insert_final_newline, 1)
    assert_equal(c.max_line_length, 100)


def test_keys_and_values_ignore_case() raises:
    var c = _config(
        " Indent_Style ", "TAB", "END_OF_LINE", "CRLF",
        "Trim_Trailing_Whitespace", "False", "insert_final_newline", "TRUE",
        "Charset", "UTF-8",
    )
    assert_equal(c.charset, "utf-8")
    assert_equal(c.indent_style, "tab")
    assert_equal(c.end_of_line, "crlf")
    assert_equal(c.trim_trailing_whitespace, 0)
    assert_equal(c.insert_final_newline, 1)


def test_the_smallest_values_count() raises:
    var c = _config(
        "indent_size", "1", "tab_width", "1", "max_line_length", "1",
        "trim_trailing_whitespace", "false", "insert_final_newline", "false",
    )
    assert_equal(c.indent_size, 1)
    assert_equal(c.tab_width, 1)
    assert_equal(c.max_line_length, 1)
    assert_equal(c.trim_trailing_whitespace, 0)
    assert_equal(c.insert_final_newline, 0)


def test_indent_size_tab_uses_the_tab_width() raises:
    var c = _config("indent_style", "tab", "indent_size", "2", "tab_width", "8", "indent_size", "tab")
    assert_equal(c.effective_indent_size(), 8)
    assert_equal(_config("indent_style", "space", "tab_width", "8").effective_indent_size(), 4)
    assert_equal(_config("indent_size", "3").indent_string(), "   ")
    assert_equal(_config("indent_style", "tab", "indent_size", "3").indent_string(), "\t")


def test_line_separators() raises:
    assert_equal(_config("end_of_line", "crlf").line_separator(), "\r\n")
    assert_equal(_config("end_of_line", "cr").line_separator(), "\r")
    assert_equal(_config("end_of_line", "lf").line_separator(), "\n")
    assert_equal(EditorConfig().line_separator(), "\n")


def test_a_closer_section_unsets_what_a_wider_one_set() raises:
    var root = _temp_path("_ec_unset")
    _rm_rf(root)
    _ensure_dir(root + "/docs")
    assert_true(write_file(
        root + "/.editorconfig",
        "root = true\n[*]\ntrim_trailing_whitespace = true\nend_of_line = crlf\n"
        "[*.md]\ntrim_trailing_whitespace = unset\n",
    ))
    assert_true(write_file(root + "/docs/.editorconfig", "[*]\nend_of_line = unset\n"))
    var md = load_editorconfig_for_path(root + "/docs/a.md")
    assert_equal(md.trim_trailing_whitespace, -1)
    assert_equal(md.end_of_line, "")
    var txt = load_editorconfig_for_path(root + "/a.txt")
    assert_equal(txt.trim_trailing_whitespace, 1)
    assert_equal(txt.end_of_line, "crlf")
    _rm_rf(root)


def test_sections_are_matched_against_the_path_from_the_files_folder() raises:
    var root = _temp_path("_ec_anchored")
    _rm_rf(root)
    _ensure_dir(root + "/src/deep")
    _ensure_dir(root + "/sub")
    assert_true(write_file(
        root + "/.editorconfig",
        "root = true\n"
        "[*.py]\nindent_size = 3\n"        # doesn't match: skipped, not the end
        "[src/*.c]\nindent_size = 5\n"
        "[/Makefile]\nindent_style = tab\n"
        "[*.c]\ntab_width = 7\n"
        "[src/deep/*]\ntab_width = 9\n",  # a later section wins
    ))
    var c = load_editorconfig_for_path(root + "/src/a.c")
    assert_equal(c.indent_size, 5)
    assert_equal(c.tab_width, 7)
    # a file that isn't there yet (Save As) is matched the same way
    var new = load_editorconfig_for_path(root + "/src/new.c")
    assert_equal(new.indent_size, 5)
    var deep = load_editorconfig_for_path(root + "/src/deep/b.c")
    assert_equal(deep.indent_size, -1)
    assert_equal(deep.tab_width, 9)
    assert_equal(load_editorconfig_for_path(root + "/Makefile").indent_style, "tab")
    assert_equal(load_editorconfig_for_path(root + "/sub/Makefile").indent_style, "")
    # a relative path
    assert_equal(load_editorconfig_for_path(root + "/sub/../src/a.c").indent_size, 5)
    _rm_rf(root)


def test_a_root_file_stops_the_walk_up() raises:
    var root = _temp_path("_ec_root_stop")
    _rm_rf(root)
    _ensure_dir(root + "/inner")
    assert_true(write_file(root + "/.editorconfig", "[*]\nindent_size = 2\ntab_width = 3\n"))
    assert_true(write_file(root + "/inner/.editorconfig", "root = true\n[*]\ntab_width = 8\n"))
    var c = load_editorconfig_for_path(root + "/inner/x.txt")
    assert_equal(c.indent_size, -1)
    assert_equal(c.tab_width, 8)
    # without it the outer file applies too, the inner one winning
    assert_true(write_file(root + "/inner/.editorconfig", "[*]\ntab_width = 8\n"))
    c = load_editorconfig_for_path(root + "/inner/x.txt")
    assert_equal(c.indent_size, 2)
    assert_equal(c.tab_width, 8)
    _rm_rf(root)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
