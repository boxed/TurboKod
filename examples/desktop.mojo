"""Desktop demo using the high-level mojovision widgets.

Set up a `Desktop` (which owns a menu bar, window manager, status bar, and
hatched background) and let it route mouse events. The app only handles the
returned action strings and the keyboard.

Mouse:
  * click a menu name to open its dropdown; click an item or click outside to close
  * click any window to focus it (and bring it to the top of the z-order)
  * drag a focused window's title bar to move it
  * click [■] in the title bar to close the focused window
  * drag the bottom-right corner cell to resize the focused window
Keyboard:
  * q or ESC to quit (ESC also closes an open dropdown first)

Run with::

    pixi run desktop
    # or
    ./run.sh examples/desktop.mojo
"""

from std.collections.list import List

from mojovision import (
    Application, Desktop, Menu, MenuItem, Rect, StatusItem, Window,
    EVENT_KEY, KEY_ESC,
)


fn _lines(*texts: String) -> List[String]:
    var out = List[String]()
    for t in texts:
        out.append(String(t))
    return out^


fn _mk_menu(var label: String, *items: Tuple[String, String]) -> Menu:
    var list = List[MenuItem]()
    for it in items:
        list.append(MenuItem(it[0], it[1]))
    return Menu(label^, list^)


fn main() raises:
    var app = Application()
    app.start()
    try:
        var desktop = Desktop()

        desktop.menu_bar.add(_mk_menu(String("File"),
            (String("New"), String("noop")),
            (String("Open..."), String("noop")),
            (String("Quit"), String("quit")),
        ))
        desktop.menu_bar.add(_mk_menu(String("Window"),
            (String("Notes"), String("focus:Notes")),
            (String("Mouse"), String("focus:Mouse")),
            (String("About"), String("focus:About")),
        ))
        desktop.menu_bar.add(_mk_menu(String("Help"),
            (String("About"), String("focus:About")),
        ))

        desktop.windows.add(Window(String("Notes"), Rect(4, 3, 38, 13), _lines(
            String("Welcome to Mojovision!"),
            String(""),
            String("Demonstrates:"),
            String(" * sub-windows"),
            String(" * menu bar"),
            String(" * status bar"),
            String(""),
            String("Drag any title bar."),
        )))
        desktop.windows.add(Window(String("Mouse"), Rect(20, 8, 56, 16), _lines(
            String("Click a window to focus."),
            String(""),
            String("Drag the title bar."),
            String("Drag bottom-right to resize."),
            String("Click [■] to close."),
        )))
        desktop.windows.add(Window(String("About"), Rect(40, 5, 70, 11), _lines(
            String("Mojovision v0.1"),
            String(""),
            String("A Mojo-idiomatic port"),
            String("of Turbo Vision."),
        )))

        desktop.status_bar.add(String("F1"),  String("Help"))
        desktop.status_bar.add(String("F2"),  String("Save"))
        desktop.status_bar.add(String("F3"),  String("Open"))
        desktop.status_bar.add(String("F9"),  String("Make"))
        desktop.status_bar.add(String("F10"), String("Menu"))
        desktop.status_bar.add(String("ESC"), String("Quit"))

        while app.running:
            app.clear()
            desktop.paint(app.back, app.screen())
            app.present()

            var maybe_ev = app.next_event(50)
            if not maybe_ev:
                continue
            var ev = maybe_ev.value()

            if ev.kind == EVENT_KEY:
                if ev.key == KEY_ESC:
                    if desktop.menu_bar.is_open():
                        desktop.menu_bar.close()
                    else:
                        app.quit()
                elif ev.is_char(UInt32(ord("q"))):
                    app.quit()
                continue

            var maybe_action = desktop.handle_event(ev, app.screen())
            if maybe_action:
                var action = maybe_action.value()
                if action == String("quit"):
                    app.quit()
                elif action == String("focus:Notes"):
                    desktop.windows.focus_by_title(String("Notes"))
                elif action == String("focus:Mouse"):
                    desktop.windows.focus_by_title(String("Mouse"))
                elif action == String("focus:About"):
                    desktop.windows.focus_by_title(String("About"))
    finally:
        app.stop()
