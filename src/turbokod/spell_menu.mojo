"""The menu that opens on Alt+Enter over a misspelled word: add it to the
user-wide dictionary, or to the current project's. The latter is disabled
(still listed, greyed) when no project is open — making the option
disappear would be more confusing than greying it out. An
``AnchoredMenu`` the host opens with ``spell_menu_items``, the word as its
``subject``.
"""

from std.collections.list import List

from .anchored_menu import NativeMenuItem


comptime SPELL_ACTION_NONE        = 0
"""The menu was dismissed (Esc / click-outside). No persistence work for
the host to do."""
comptime SPELL_ACTION_ADD_USER    = 1
"""Add the word to the user-wide dictionary."""
comptime SPELL_ACTION_ADD_PROJECT = 2
"""Add the word to the project-local dictionary."""


def spell_menu_items(has_project: Bool) -> List[NativeMenuItem]:
    """The rows, user dictionary first: the default selection, because
    "stay personal unless I deliberately share" is the safer pick."""
    var out = List[NativeMenuItem]()
    out.append(NativeMenuItem(
        String("Add to user dictionary"), SPELL_ACTION_ADD_USER, True,
    ))
    out.append(NativeMenuItem(
        String("Add to project dictionary"), SPELL_ACTION_ADD_PROJECT,
        has_project,
    ))
    return out^
