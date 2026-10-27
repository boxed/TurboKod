"""``match_section``: which files an ``.editorconfig`` section applies to.
A wrong match trims whitespace or changes line endings in files it
shouldn't touch."""

from std.testing import TestSuite, assert_false, assert_true
from turbokod.editorconfig import match_section


def test_a_star_stays_within_a_directory() raises:
    assert_true(match_section("src/*.py", "src/a.py"))
    assert_true(match_section("src/*.py", "src/.py"))
    assert_false(match_section("src/*.py", "src/sub/a.py"))
    assert_false(match_section("src/*.py", "src/a.pyc"))
    assert_true(match_section("a*", "a"))


def test_a_pattern_without_a_slash_matches_the_name_anywhere() raises:
    assert_true(match_section("*.md", "README.md"))
    assert_true(match_section("*.md", "docs/deep/x.md"))
    assert_false(match_section("*.md", "docs/x.mdx"))
    assert_true(match_section("Makefile", "sub/Makefile"))
    assert_false(match_section("Makefile", "sub/GNUMakefile"))


def test_a_leading_slash_anchors_the_pattern() raises:
    assert_true(match_section("/Makefile", "Makefile"))
    assert_false(match_section("/Makefile", "sub/Makefile"))
    assert_true(match_section("lib/", "lib"))


def test_a_double_star_crosses_directories() raises:
    assert_true(match_section("src/**/*.c", "src/a/b/x.c"))
    assert_true(match_section("src/**/x.c", "src/x.c"))
    assert_true(match_section("src/**", "src/a/b"))
    assert_false(match_section("src/**/x.c", "lib/x.c"))
    assert_true(match_section("**.c", "a/b.c"))


def test_a_question_mark_is_one_character_but_not_a_slash() raises:
    assert_true(match_section("a?c", "abc"))
    assert_false(match_section("a?c", "ac"))
    assert_false(match_section("x/a?c", "x/a/c"))
    assert_false(match_section("a?", "a"))


def test_character_classes() raises:
    assert_true(match_section("[abc].txt", "b.txt"))
    assert_false(match_section("[abc].txt", "d.txt"))
    assert_true(match_section("[!abc].txt", "d.txt"))
    assert_false(match_section("[!abc].txt", "a.txt"))
    assert_true(match_section("[a-c].txt", "a.txt"))
    assert_true(match_section("[a-c].txt", "c.txt"))
    assert_false(match_section("[a-c].txt", "d.txt"))
    assert_true(match_section("[xa-c].txt", "x.txt"))
    assert_true(match_section("[a-cx].txt", "x.txt"))
    assert_true(match_section("[!abc].txt", "!.txt"))
    assert_false(match_section("[ab]x", "]x"))
    # a dash at the end is a dash
    assert_true(match_section("[a-]", "-"))
    assert_true(match_section("[a-]", "a"))
    assert_false(match_section("x/[ab]", "x/"))
    assert_false(match_section("x[/]y", "x/y"))


def test_an_unclosed_bracket_is_literal() raises:
    assert_true(match_section("a[b", "a[b"))
    assert_false(match_section("a[b", "ab"))
    assert_false(match_section("a[", "a"))


def test_alternations() raises:
    assert_true(match_section("*.{js,ts}", "a.ts"))
    assert_true(match_section("*.{js,ts}", "a.js"))
    assert_false(match_section("*.{js,ts}", "a.py"))
    assert_true(match_section("{a,{b,c}}.x", "c.x"))
    assert_true(match_section("{a,b}{1,2}", "b2"))
    assert_true(match_section("{a,b", "{a,b"))
    assert_true(match_section("{a,{b,c}}.x", "a.x"))
    assert_true(match_section("{{a,b},c}.x", "a.x"))
    assert_true(match_section("{{a,b},c}.x", "c.x"))
    assert_true(match_section("{x,{y,{z,w}}}.q", "w.q"))
    assert_true(match_section("{}x", "x"))
    assert_true(match_section("{a,b}c", "ac"))
    assert_false(match_section("{a,b}c", "a"))
    assert_true(match_section("/{src,lib}/x.c", "lib/x.c"))
    assert_false(match_section("/{src,lib}/x.c", "doc/x.c"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
