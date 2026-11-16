"""The menu that opens when the user clicks the gutter run-icon next to a
detected test: run the single test, or run it under the debugger. An
``AnchoredMenu`` the host opens with ``test_menu_items``, the pytest node
id of the clicked test as its ``subject`` — so the host doesn't re-derive
which test was clicked.
"""

from std.collections.list import List

from .anchored_menu import NativeMenuItem


comptime TEST_ACTION_NONE  = 0
comptime TEST_ACTION_RUN   = 1
comptime TEST_ACTION_DEBUG = 2


def test_menu_items() -> List[NativeMenuItem]:
    var out = List[NativeMenuItem]()
    out.append(NativeMenuItem(String("Run test"), TEST_ACTION_RUN, True))
    out.append(NativeMenuItem(String("Debug test"), TEST_ACTION_DEBUG, True))
    return out^
