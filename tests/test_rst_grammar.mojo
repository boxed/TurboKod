"""Standalone smoke test for the bundled rST TextMate grammar.

Lives outside ``test_basic.mojo`` so it can be exercised without
running the full suite (which currently has unrelated failures in
this checkout). Once ``test_basic.mojo`` is green again, the same
assertions are duplicated in
``test_highlight_rst_grammar_paints_common_constructs`` there.
"""

from std.collections.list import List

from turbokod.highlight import (
    highlight_comment_attr, highlight_for_extension,
    highlight_ident_attr, highlight_keyword_attr, highlight_operator_attr,
    highlight_string_attr,
)


def _lines(*texts: String) -> List[String]:
    var out = List[String]()
    for t in texts:
        out.append(String(t))
    return out^


def main() raises:
    var lines = _lines(
        String("Section Title"),
        String("============="),
        String(""),
        String(".. note:: a directive argument"),
        String(""),
        String(".. a plain rST comment"),
        String(""),
        String("This is ``inline literal`` text."),
        String("With *italic* and **bold** and a :ref:`role text`."),
        String("And a footnote ref [1]_ and a |sub| ref."),
        String("- bullet item"),
        String(":field: value"),
    )
    var hls = highlight_for_extension(String("rst"), lines)
    if len(hls) == 0:
        raise Error(
            String("rST grammar produced zero highlights — grammar didn't load?")
        )

    var saw_heading = False
    var saw_directive_ident = False
    var saw_literal = False
    var saw_comment = False
    var saw_italic_ident = False
    var saw_bold_keyword = False
    var saw_role_ident = False
    var saw_list_op = False
    var saw_field_ident = False

    for i in range(len(hls)):
        var h = hls[i]
        var a = h.attr
        if h.row == 1 and a == highlight_keyword_attr():
            saw_heading = True
        if h.row == 3 and a == highlight_ident_attr():
            saw_directive_ident = True
        if h.row == 5 and a == highlight_comment_attr():
            saw_comment = True
        if h.row == 7 and a == highlight_string_attr():
            saw_literal = True
        if h.row == 8 and a == highlight_ident_attr():
            saw_italic_ident = True
        if h.row == 8 and a == highlight_keyword_attr():
            saw_bold_keyword = True
        if h.row == 8 and a == highlight_string_attr():
            saw_role_ident = True
        if h.row == 10 and a == highlight_operator_attr():
            saw_list_op = True
        if h.row == 11 and a == highlight_ident_attr():
            saw_field_ident = True

    if not saw_heading:
        raise Error(String("missing section adornment highlight"))
    if not saw_directive_ident:
        raise Error(String("missing directive-name highlight"))
    if not saw_comment:
        raise Error(String("missing rST comment highlight"))
    if not saw_literal:
        raise Error(String("missing inline-literal highlight"))
    if not saw_italic_ident:
        raise Error(String("missing emphasis highlight"))
    if not saw_bold_keyword:
        raise Error(String("missing strong highlight"))
    if not saw_role_ident:
        raise Error(String("missing role/interpreted-text highlight"))
    if not saw_list_op:
        raise Error(String("missing list-marker highlight"))
    if not saw_field_ident:
        raise Error(String("missing field-list highlight"))

    print(
        String("rST grammar OK: ") + String(len(hls)) + String(" highlights")
    )
