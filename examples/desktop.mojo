"""Desktop demo using the high-level mojovision widgets.

Mouse:
  * click a menu name to open its dropdown; click an item or click outside to close
  * click any window to focus it (and bring it to the top of the z-order)
  * drag a focused window's title bar to move it
  * click [■] in the title bar to close the focused window
  * drag any edge / bottom corner to resize
  * click in an editor window to place the cursor; drag to select
Keyboard:
  * arrows navigate; shift+arrow extends selection; ctrl+arrow moves by word;
    shift+ctrl+arrow extends by word
  * Ctrl+C / Ctrl+X / Ctrl+V copy / cut / paste via the system clipboard
  * Edit menu (visible only when an editor window is focused): Find,
    Replace, Find/Replace in project, Go to Line, Toggle Comment, Toggle Case
  * ESC quits (and closes any open menu / dialog first)

Run with::

    pixi run desktop                                  # demo windows
    ./run.sh examples/desktop.mojo path/to/file.txt   # open file(s)

The Desktop owns all the standard editor / project actions (save, find,
replace, project search, etc.). The demo only handles app-policy actions:
opening a file dialog, focusing demo windows, quitting.
"""

from std.collections.list import List
from std.sys import argv

from mojovision import (
    APP_QUIT_ACTION, Application, Desktop, FileDialog, Menu, MenuItem, Rect,
    Window, EDITOR_FIND, EDITOR_GOTO, EDITOR_REPLACE, EDITOR_SAVE,
    EDITOR_SAVE_AS, EDITOR_TOGGLE_CASE, EDITOR_TOGGLE_COMMENT,
    EVENT_KEY, PROJECT_FIND, PROJECT_REPLACE,
)


fn _basename(path: String) -> String:
    var bytes = path.as_bytes()
    var i = len(bytes) - 1
    while i >= 0 and bytes[i] != 0x2F:
        i -= 1
    if i < 0:
        return path
    return String(StringSlice(unsafe_from_utf8=bytes[i + 1:]))


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
    var error_log = List[String]()        # populated in the loop, drained on quit
    app.start()
    try:
        var desktop = Desktop()
        var file_dialog = FileDialog()

        desktop.menu_bar.add(_mk_menu(String("File"),
            (String("New"), String("noop")),
            (String("Open..."), String("file:open")),
            (String("Save"), EDITOR_SAVE),
            (String("Save as..."), EDITOR_SAVE_AS),
            (String("Quit"), APP_QUIT_ACTION),
        ))
        desktop.menu_bar.add(_mk_menu(String("Edit"),
            (String("Find..."), EDITOR_FIND),
            (String("Replace..."), EDITOR_REPLACE),
            (String("Find in project..."), PROJECT_FIND),
            (String("Replace in project..."), PROJECT_REPLACE),
            (String("Go to Line..."), EDITOR_GOTO),
            (String("Toggle Comment"), EDITOR_TOGGLE_COMMENT),
            (String("Toggle Case"), EDITOR_TOGGLE_CASE),
        ))
        desktop.menu_bar.add(_mk_menu(String("Window"),
            (String("Editor"), String("focus:editor.txt")),
            (String("Mouse"), String("focus:Mouse")),
            (String("About"), String("focus:About")),
        ))
        desktop.menu_bar.add(_mk_menu(String("Help"),
            (String("About"), String("focus:About")),
        ))

        # Files passed on the command line replace the demo windows; without
        # arguments we open the canned tour content instead.
        var args = argv()
        var has_files = len(args) > 1
        if has_files:
            var ox = 4
            var oy = 3
            for i in range(1, len(args)):
                var path = String(args[i])
                desktop.detect_project_from(path)
                try:
                    desktop.windows.add(Window.from_file(
                        _basename(path), Rect(ox, oy, ox + 56, oy + 16), path,
                    ))
                except e:
                    error_log.append(
                        String("open ") + path + String(": ") + String(e),
                    )
                ox += 3
                oy += 2
        else:
            desktop.windows.add(Window.editor_window(
                String("editor.txt"),
                Rect(4, 3, 50, 16),
                String("// A tiny pure-Mojo text editor.\n")
                    + String("// Type to insert; arrows navigate.\n")
                    + String("// Ctrl+C/X/V cut/copy/paste, Ctrl+arrow word jump.\n")
                    + String("// Open the Edit menu for Find / Go to Line / etc.\n")
                    + String("\n")
                    + String("fn main() raises:\n")
                    + String("    print(\"Hello, Mojovision!\")\n"),
            ))
            desktop.windows.add(Window(String("Mouse"), Rect(20, 8, 56, 16), _lines(
                String("Click a window to focus."),
                String(""),
                String("Drag the title bar."),
                String("Drag any edge to resize."),
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
            try:
                # Reload any file-backed editor whose file changed on disk and
                # has no unsaved edits. Stat is cheap; do it every frame.
                _ = desktop.windows.check_external_changes()
            except e:
                error_log.append(String("reload: ") + String(e))
            # Edit menu visibility tracks whether the focused window is an editor.
            desktop.menu_bar.set_visible_by_label(
                String("Edit"), desktop.windows.focused_is_editor(),
            )
            # If the user clicked a file in the project tree last frame, open it.
            var tree_open = desktop.file_tree.consume_open()
            if tree_open:
                var p = tree_open.value()
                try:
                    desktop.windows.add(Window.from_file(
                        _basename(p), Rect(6, 4, 60, 20), p,
                    ))
                except e:
                    error_log.append(String("open ") + p + String(": ") + String(e))

            app.clear()
            desktop.paint(app.back, app.screen())
            file_dialog.paint(app.back, app.screen())
            try:
                app.present()
            except e:
                error_log.append(String("present: ") + String(e))
                continue

            var maybe_ev = app.next_event(50)
            if not maybe_ev:
                continue
            var ev = maybe_ev.value()

            # Modal: file dialog eats every event while open.
            if file_dialog.active:
                if ev.kind == EVENT_KEY:
                    _ = file_dialog.handle_key(ev)
                else:
                    _ = file_dialog.handle_mouse(ev, app.screen())
                if file_dialog.submitted:
                    var path = file_dialog.selected_path
                    file_dialog.close()
                    desktop.detect_project_from(path)
                    try:
                        desktop.windows.add(Window.from_file(
                            _basename(path), Rect(6, 4, 60, 20), path,
                        ))
                    except:
                        pass
                continue

            var maybe_action = desktop.handle_event(ev, app.screen())
            if maybe_action:
                var action = maybe_action.value()
                if action == APP_QUIT_ACTION:
                    app.quit()
                elif action == String("file:open"):
                    file_dialog.open(String("."))
                elif action == String("focus:editor.txt"):
                    desktop.windows.focus_by_title(String("editor.txt"))
                elif action == String("focus:Mouse"):
                    desktop.windows.focus_by_title(String("Mouse"))
                elif action == String("focus:About"):
                    desktop.windows.focus_by_title(String("About"))
    finally:
        app.stop()
        for i in range(len(error_log)):
            print(error_log[i])
