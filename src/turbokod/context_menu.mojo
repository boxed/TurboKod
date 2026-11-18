"""Popup menu that opens when the user right-clicks plain identifier
text in the editor's text area (i.e. not a diagnostic squiggle and not a
breakpoint gutter dot).

It offers the symbol actions that otherwise live behind Cmd+click or a
keybinding: rename, the go-to family (definition / type definition /
implementation / declaration), and find references. The host (Desktop)
decides *which* rows to show — it builds the label/action lists at open
time, filtered by what the language server actually advertises, so a
server without an ``implementationProvider`` simply doesn't get that row.

The same popup serves right-clicks in the gutter, with a fixed row set
(Toggle Blame / Copy Location / Toggle Bookmark / Toggle Breakpoint).

The popup itself is an ``AnchoredMenu``; this module holds its action
codes. Rows come in groups divided by ``NativeMenuItem.separator()``s.
"""


comptime CTX_MENU_ACTION_NONE            = 0
comptime CTX_MENU_ACTION_RENAME          = 1
comptime CTX_MENU_ACTION_DEFINITION      = 2
comptime CTX_MENU_ACTION_REFERENCES      = 3
comptime CTX_MENU_ACTION_TYPE_DEFINITION = 4
comptime CTX_MENU_ACTION_IMPLEMENTATION  = 5
comptime CTX_MENU_ACTION_DECLARATION     = 6
comptime CTX_MENU_ACTION_CALLERS         = 7
comptime CTX_MENU_ACTION_SUPERTYPES      = 8
comptime CTX_MENU_ACTION_CALLEES         = 9
comptime CTX_MENU_ACTION_SUBTYPES        = 10
comptime CTX_MENU_ACTION_MONIKER         = 11
comptime CTX_MENU_ACTION_COLOR_PRESENTATION = 12
comptime CTX_MENU_ACTION_INLINE_COMPLETION = 13
comptime CTX_MENU_ACTION_LINKED_EDIT = 14
comptime CTX_MENU_ACTION_TOGGLE_FOLD = 15
comptime CTX_MENU_ACTION_COLOR_PICKER = 16
# Gutter menu rows (right-click in the line-number / gutter strip).
comptime CTX_MENU_ACTION_TOGGLE_BLAME = 17
comptime CTX_MENU_ACTION_COPY_LOCATION = 18
comptime CTX_MENU_ACTION_TOGGLE_BOOKMARK = 19
comptime CTX_MENU_ACTION_TOGGLE_BREAKPOINT = 20
comptime CTX_MENU_ACTION_EDIT_BREAKPOINT = 21
comptime CTX_MENU_ACTION_SEND_TO_CLAUDE = 22
