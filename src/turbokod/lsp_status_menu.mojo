"""The menu that opens when the user right-clicks the LSP indicator on the
right of the status bar: restart the language server for the focused
editor's file. An ``AnchoredMenu`` the host opens above the status bar
with ``lsp_menu_items``.
"""

from std.collections.list import List

from .anchored_menu import NativeMenuItem


comptime LSP_MENU_ACTION_NONE    = 0
comptime LSP_MENU_ACTION_RESTART = 1


def lsp_menu_items() -> List[NativeMenuItem]:
    var out = List[NativeMenuItem]()
    out.append(NativeMenuItem(
        String("Restart LSP"), LSP_MENU_ACTION_RESTART, True,
    ))
    return out^
