"""The pickers as one declarative dialog.

Quick Open, Go to Symbol, references, Find Symbol, docs and Find in
Project are the same dialog: a search field over a long list (``UI_LIST``,
sent a window at a time), a status line, and Find in Project's extra
fields and its code view of the selected match. ``picker_dialog`` lays
that out once; the ``*_rows`` functions are each picker's rows. Every
projector — the grid, AppKit, Platinum — draws the result, so a picker
looks like the rest of the look it's in.

The search machinery stays in each picker; ``Desktop.picker_apply`` feeds
the edits and actions back to it.
"""

from std.collections.list import List

from .colors import RED, WHITE
from .doc_pick import DocPick
from .file_io import basename, parent_path, project_relative
from .find_symbol import FindSymbol
from .project_find import ProjectFind
from .quick_open import QuickOpen
from .reference_pick import ReferencePick
from .string_utils import byte_slice
from .symbol_pick import SymbolPick
from .ui_tree import (
    UI_CANCEL, UI_CODE, UI_DEFAULT, UI_DISABLED, UI_LARGE, UI_MULTI, UI_NAV,
    UI_SECONDARY, UINode, UISpan, ui_button, ui_buttons, ui_check, ui_dialog,
    ui_form, ui_hstack, ui_label, ui_list, ui_row, ui_text, ui_vstack,
)


def picker_dialog(
    var title: String, var query: UINode, var results: UINode,
    var status: String, var extra: List[UINode] = List[UINode](),
    var code: List[UINode] = List[UINode](),
    var actions: List[UINode] = List[UINode](),
) -> UINode:
    """Search field(s) (``query``: a form, or a spacer for a picker that
    doesn't search), the results list, an optional code view, the status
    line (no room while empty), and Cancel / ``actions`` / Open."""
    var body = List[UINode]()
    body.append(query^)
    for i in range(len(extra)):
        body.append(extra[i].copy())
    body.append(results^)
    for i in range(len(code)):
        body.append(code[i].copy())
    # Always there, so the tree keeps its shape as the status comes and goes
    # (the native projectors rebuild their views, and lose the field's
    # focus, on a new shape); empty, it takes no room in any look.
    body.append(ui_label(status^, UI_SECONDARY))
    var buttons = List[UINode]()
    buttons.append(ui_button(String("cancel"), String("Cancel"), UI_CANCEL))
    for i in range(len(actions)):
        buttons.append(actions[i].copy())
    buttons.append(ui_button(String("open"), String("Open"), UI_DEFAULT))
    body.append(ui_buttons(buttons^))
    var d = ui_dialog(title^, String("cancel"), ui_vstack(body^))
    d.flags |= UI_LARGE
    return d^


def picker_query(
    var label: String, var value: String, var placeholder: String,
    var more: List[UINode] = List[UINode](),
) -> UINode:
    """The search field — typing filters, the arrows move the list — and
    ``more`` form rows under it, sharing its label column."""
    var field = ui_text(String("query"), value^, placeholder^)
    field.flags |= UI_NAV
    var rows = List[UINode]()
    rows.append(ui_row(label^, field^))
    for i in range(len(more)):
        rows.append(more[i].copy())
    return ui_form(rows^, 0)


def picker_list(
    count: Int, first: Int, var rows: List[List[String]], var selected: String,
    multi: Bool = False, height: Int = 16,
    var spans: List[UISpan] = List[UISpan](),
) -> UINode:
    return ui_list(
        String("results"), count, first, rows^, selected^, String("open"),
        height, UI_MULTI if multi else 0, spans^,
    )


# --- each picker's rows ----------------------------------------------------------


def quick_open_rows(q: QuickOpen, first: Int, end: Int) -> List[List[String]]:
    var out = List[List[String]]()
    for i in range(first, end):
        var rel = q.entries[q.matched[i]]
        var dir = parent_path(rel)
        if dir == String("."):
            dir = String("")
        out.append([basename(rel), dir^])
    return out^


def find_symbol_rows(f: FindSymbol, first: Int, end: Int) -> List[List[String]]:
    var out = List[List[String]]()
    for i in range(first, end):
        ref e = f.entries[i]
        var detail = project_relative(f.root, e.path) + String(":") + String(e.line)
        if len(e.container.as_bytes()) > 0:
            detail = e.container + String(" — ") + detail
        out.append([e.name, detail^])
    return out^


def symbol_pick_rows(sp: SymbolPick, first: Int, end: Int) -> List[List[String]]:
    var out = List[List[String]]()
    for i in range(first, end):
        ref e = sp.entries[sp.matched[i]]
        var detail = String("line ") + String(e.line + 1)
        if len(e.container.as_bytes()) > 0:
            detail = e.container + String(" · ") + detail
        out.append([e.name, detail^])
    return out^


def reference_pick_rows(rp: ReferencePick, first: Int, end: Int) -> List[List[String]]:
    var out = List[List[String]]()
    for i in range(first, end):
        ref e = rp.entries[i]
        var rel = project_relative(rp.project_root, e.path)
        out.append([basename(rel) + String(":") + String(e.line + 1), parent_path(rel)])
    return out^


def doc_pick_rows(dp: DocPick, first: Int, end: Int) -> List[List[String]]:
    var out = List[List[String]]()
    for i in range(first, end):
        ref e = dp.entries[dp.matched[i]]
        out.append([e.name, e.type_name])
    return out^


def project_find_rows(
    p: ProjectFind, first: Int, end: Int,
) -> Tuple[List[List[String]], List[UISpan]]:
    """Each match's line, its hit marked, with ``path:line`` as detail."""
    var out = List[List[String]]()
    var spans = List[UISpan]()
    var qn = len(p.query.text.as_bytes())
    for i in range(first, end):
        var hit = p.row_hit(i)
        out.append([hit[0], p.matches[i].rel + String(":") + String(p.matches[i].line_no)])
        if hit[1] >= 0 and qn > 0:
            spans.append(UISpan(i, 0, hit[1], hit[1] + qn, Int(WHITE), Int(RED)))
    return (out^, spans^)


def project_find_fields(p: ProjectFind) -> List[UINode]:
    """The form rows under Find: Replace, the folder, the files."""
    var rows = List[UINode]()
    var replace = ui_text(String("replace"), p.replace.text, String("Replacement"))
    if not p.replace_mode:
        replace.flags |= UI_DISABLED
    rows.append(ui_row(String("Replace"), replace^))
    rows.append(ui_row(
        String("In folder"),
        ui_text(String("scope"), p.scope.text, String("relative to the project")),
    ))
    rows.append(ui_row(
        String("Files"),
        ui_text(String("glob"), p.glob.text, String("e.g. *.py, !tests/**")),
    ))
    return rows^


def project_find_toggles(p: ProjectFind) -> List[UINode]:
    """Match case / whole word / regular expression, in one row."""
    var toggles = List[UINode]()
    toggles.append(ui_check(String("case"), String("Match case"), p.toggle_case.on))
    toggles.append(ui_check(String("word"), String("Whole word"), p.toggle_word.on))
    toggles.append(ui_check(String("regex"), String("Regular expression"), p.toggle_regex.on))
    var out = List[UINode]()
    out.append(ui_hstack(toggles^))
    return out^
