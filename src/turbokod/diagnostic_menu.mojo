"""Popup menu that opens when the user right-clicks a diagnostic
(LSP inspection error/warning/info/hint) squiggle in the editor's
text area, or hits Alt+Enter while the cursor is on one.

It is an ``AnchoredMenu`` (its subject the diagnostic text) whose rows
``diagnostic_menu_items`` builds: ``Copy message`` (push the text to the
clipboard — for pasting into a search / chat / bug tracker), the LSP
code-action quick fixes above it once they arrive, and while the host
still waits for the ``textDocument/codeAction`` response a disabled
``Loading fixes…`` row, so the user sees more options are on the way.
The host (Desktop) opens it in response to
``Editor.consume_diagnostic_menu_request`` and swaps the rows in with
``AnchoredMenu.set_items`` as the response state changes.
"""

from std.collections.list import List

from .lsp_dispatch import Diagnostic
from .anchored_menu import NativeMenuItem


comptime DIAG_MENU_ACTION_NONE      = 0
comptime DIAG_MENU_ACTION_COPY      = 1


comptime NATIVE_FIX_BASE = 100
"""Action codes of the quick-fix rows: ``NATIVE_FIX_BASE + i`` picks the
``i``-th fix."""


comptime _LABEL_COPY    = String("Copy message")
comptime _LABEL_LOADING = String("Loading fixes…")


@fieldwise_init
struct DiagnosticMenuRequest(ImplicitlyCopyable, Movable):
    """Payload emitted when the user opens the diagnostic menu —
    right-click on a squiggle in the text area or Alt+Enter while the
    cursor sits on one.

    ``message`` is the formatted ``[source] text`` label the menu copies
    on the Copy row. ``anchor_x``/``anchor_y`` are the container_bounds cell the
    menu should open against (immediately below the underlined span,
    left-aligned to its leftmost cell). ``diag`` is the underlying LSP
    diagnostic — the host forwards its range + severity + message in
    the ``textDocument/codeAction`` request so servers like ty / pyright
    can return quickfixes keyed to that specific diagnostic."""
    var message: String
    var anchor_x: Int
    var anchor_y: Int
    var diag: Diagnostic


def diagnostic_menu_items(
    fix_titles: List[String], loading_fixes: Bool,
) -> List[NativeMenuItem]:
    """The menu's rows, top to bottom: one per quick fix (answering
    ``NATIVE_FIX_BASE + index``), a disabled ``Loading fixes…`` while the
    code-action request is in flight, and ``Copy message`` last. The
    first pickable row is selected — the first fix once any arrived,
    since that's why the user opened the menu."""
    var out = List[NativeMenuItem]()
    for i in range(len(fix_titles)):
        out.append(NativeMenuItem(fix_titles[i], NATIVE_FIX_BASE + i, True))
    if loading_fixes:
        out.append(NativeMenuItem(_LABEL_LOADING, DIAG_MENU_ACTION_NONE, False))
    out.append(NativeMenuItem(_LABEL_COPY, DIAG_MENU_ACTION_COPY, True))
    return out^
