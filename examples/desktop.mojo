"""Desktop demo using the high-level turbokod widgets.

Mouse:
  * click a menu name to open its dropdown; click an item or click outside to close
  * click any window to focus it (and bring it to the top of the z-order)
  * drag a focused window's title bar to move it
  * click [■] in the title bar to close the focused window
  * drag any edge / bottom corner to resize
  * click in an editor window to place the cursor; drag to select
  * cmd+click an identifier in a Mojo file to jump to its definition (LSP)
Keyboard:
  * arrows navigate; shift+arrow extends selection; ctrl+arrow moves by word;
    shift+ctrl+arrow extends by word
  * Ctrl+C / Ctrl+X / Ctrl+V copy / cut / paste via the system clipboard
  * Edit menu (visible only when an editor window is focused): Find,
    Replace, Find/Replace in project, Go to Line, Toggle Comment, Toggle Case
  * ESC closes any open menu / dialog. Ctrl+Q quits.

Run with::

    pixi run desktop                                  # demo windows
    ./run.sh examples/desktop.mojo path/to/file.txt   # open file(s)

The Desktop owns all the standard editor / project actions (save, find,
replace, project search, etc.). The demo only handles app-policy actions:
opening a file dialog, focusing demo windows, quitting.

editorconfig: any ``.editorconfig`` files (https://editorconfig.org/) found
walking up from an opened file's directory are honored automatically.
Supported keys: ``indent_style`` / ``indent_size`` / ``tab_width`` (drive
the Tab key), ``end_of_line``, ``trim_trailing_whitespace``,
``insert_final_newline`` (applied on save). No host wiring needed — the
editor loads the resolved config in ``Editor.from_file``.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.sys import argv

from turbokod import (
    APP_QUIT_ACTION, Application,
    Event,
    DEBUG_ADD_WATCH, DEBUG_CONDITIONAL_BP,
    DEBUG_START_OR_CONTINUE,
    DEBUG_STEP_IN, DEBUG_STEP_OUT, DEBUG_STEP_OVER, DEBUG_STOP,
    DEBUG_TOGGLE_BREAKPOINT, DEBUG_TOGGLE_RAISED,
    Desktop, FileDialog, Menu, MenuItem, Rect,
    Window, EDITOR_COPY, EDITOR_CUT, EDITOR_FIND, EDITOR_GOTO,
    EDITOR_GOTO_SYMBOL, EDITOR_NEW, EDITOR_PASTE, EDITOR_QUICK_OPEN,
    EDITOR_REDO, EDITOR_REPLACE, EDITOR_SAVE, EDITOR_SAVE_AS,
    EDITOR_TOGGLE_CASE, EDITOR_TOGGLE_COMMENT, EDITOR_UNDO,
    EVENT_KEY, EVENT_MOUSE, EVENT_RESIZE,
    PROJECT_FIND, PROJECT_REPLACE, WINDOW_CLOSE,
    stat_file,
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
    var error_log = List[String]()        # populated in the loop, drained on quit
    app.start()
    try:
        var desktop = Desktop()
        var file_dialog = FileDialog()

        desktop.menu_bar.add(_mk_menu(String("File"),
            (String("New"), EDITOR_NEW),
            (String("Open..."), String("file:open")),
            (String("Quick open..."), EDITOR_QUICK_OPEN),
            (String("Close"), WINDOW_CLOSE),
            (String("Save"), EDITOR_SAVE),
            (String("Save as..."), EDITOR_SAVE_AS),
            (String("Quit"), APP_QUIT_ACTION),
        ))
        # Edit menu — built by hand so the separators land where they should.
        var edit_items = List[MenuItem]()
        edit_items.append(MenuItem(String("Undo"),  EDITOR_UNDO))
        edit_items.append(MenuItem(String("Redo"),  EDITOR_REDO))
        edit_items.append(MenuItem.separator())
        edit_items.append(MenuItem(String("Cut"),   EDITOR_CUT))
        edit_items.append(MenuItem(String("Copy"),  EDITOR_COPY))
        edit_items.append(MenuItem(String("Paste"), EDITOR_PASTE))
        edit_items.append(MenuItem.separator())
        edit_items.append(MenuItem(String("Find..."),               EDITOR_FIND))
        edit_items.append(MenuItem(String("Replace..."),            EDITOR_REPLACE))
        edit_items.append(MenuItem(String("Find in project..."),    PROJECT_FIND))
        edit_items.append(MenuItem(String("Replace in project..."), PROJECT_REPLACE))
        edit_items.append(MenuItem(String("Go to Line..."),         EDITOR_GOTO))
        edit_items.append(MenuItem(String("Go to Symbol..."),       EDITOR_GOTO_SYMBOL))
        edit_items.append(MenuItem(String("Toggle Comment"),        EDITOR_TOGGLE_COMMENT))
        edit_items.append(MenuItem(String("Toggle Case"),           EDITOR_TOGGLE_CASE))
        desktop.menu_bar.add(Menu(String("Edit"), edit_items^))
        desktop.menu_bar.add(_mk_menu(String("Debug"),
            (String("Start / Continue"), DEBUG_START_OR_CONTINUE),
            (String("Stop"), DEBUG_STOP),
            (String("Toggle Breakpoint"), DEBUG_TOGGLE_BREAKPOINT),
            (String("Conditional Breakpoint..."), DEBUG_CONDITIONAL_BP),
            (String("Step Over"), DEBUG_STEP_OVER),
            (String("Step Into"), DEBUG_STEP_IN),
            (String("Step Out"), DEBUG_STEP_OUT),
            (String("Add Watch..."), DEBUG_ADD_WATCH),
            (String("Toggle Break on Raised"), DEBUG_TOGGLE_RAISED),
        ))
        # The "Window" menu is owned by Desktop and rebuilt every frame from
        # the actual window list — host doesn't add one.
        desktop.menu_bar.add(_mk_menu(String("Help"),
            (String("About"), String("focus:About")),
        ))

        # Args passed on the command line replace the demo windows; without
        # arguments we open the canned tour content instead. A directory arg
        # is treated as a project root (no file opened); a regular file is
        # opened as an editor window the usual way.
        var args = argv()
        var has_args = len(args) > 1
        if has_args:
            for i in range(1, len(args)):
                var path = String(args[i])
                var info = stat_file(path)
                if info.ok and info.is_dir():
                    desktop.open_project(path)
                    continue
                try:
                    desktop.open_file(path, app.screen())
                except e:
                    error_log.append(
                        String("open ") + path + String(": ") + String(e),
                    )
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
                    + String("    print(\"Hello, Turbokod!\")\n"),
            ))
            desktop.windows.add(Window(String("Mouse"), Rect(20, 8, 56, 16), _lines(
                String("Click a window to focus."),
                String(""),
                String("Drag the title bar."),
                String("Drag any edge to resize."),
                String("Click [■] to close."),
            )))
            desktop.windows.add(Window(String("About"), Rect(40, 5, 70, 11), _lines(
                String("Turbokod v0.1"),
                String(""),
                String("A Mojo-idiomatic port"),
                String("of Turbo Vision."),
            )))

        desktop.status_bar.add(String("F1"),  String("Help"))
        desktop.status_bar.add(String("F2"),  String("Save"))
        desktop.status_bar.add(String("F3"),  String("Open"))
        desktop.status_bar.add(String("F9"),  String("Make"))
        desktop.status_bar.add(String("F10"), String("Menu"))
        desktop.status_bar.add(String("Ctrl+Q"), String("Quit"))

        var iter_n = 0
        while app.running:
            iter_n += 1
            # Stamp every iteration so a Mojo abort that bypasses our
            # catch-all leaves a trail in the trace log. If the trace
            # file ends with ``iter N before-X`` and no ``iter N after-X``,
            # ``X`` is the call that died. (Cheap: 5 syscalls / frame.)
            if desktop.dap.is_active():
                desktop.dap.client.process.trace(
                    String("iter ") + String(iter_n) + String(" start"),
                )
                # Forward the trace fd to Terminal so ``poll_event``'s
                # sub-step traces land in the same log. Idempotent.
                if app.terminal.trace_fd < 0:
                    app.terminal.trace_fd = \
                        desktop.dap.client.process.trace_fd
            # One catch-all for the whole frame. ``next_event`` and any
            # other ``raises`` call along the way (terminal cursor-size
            # query, parse failures, file_dialog mishaps, …) lands here
            # — without this an unhandled raise would silently exit the
            # process before ``app.stop()`` could restore the terminal,
            # and the user would see only an unexplained quit + leaked
            # cursor-position bytes in the shell.
            try:
                try:
                    _ = desktop.windows.check_external_changes()
                except e:
                    error_log.append(String("reload: ") + String(e))
                desktop.menu_bar.set_visible_by_label(
                    String("Edit"), desktop.windows.focused_is_editor(),
                )
                var tree_open = desktop.file_tree.consume_open()
                if tree_open:
                    var p = tree_open.value()
                    try:
                        desktop.open_file(p, app.screen())
                    except e:
                        error_log.append(
                            String("open ") + p + String(": ") + String(e),
                        )

                app.clear()
                if desktop.dap.is_active():
                    desktop.dap.client.process.trace(
                        String("iter ") + String(iter_n) + String(" before-paint"),
                    )
                desktop.paint(app.back, app.screen())
                file_dialog.paint(app.back, app.screen())
                if desktop.dap.is_active():
                    desktop.dap.client.process.trace(
                        String("iter ") + String(iter_n) + String(" before-present"),
                    )
                try:
                    app.present()
                except e:
                    error_log.append(String("present: ") + String(e))
                    continue
                # Hand-roll ``app.next_event(50)`` so each step (cursor
                # query, canvas resize, stdin read+parse) is separately
                # traced — the death on iter 340 was inside this opaque
                # call. iter 340 = 17 × 20: cursor-query frame.
                if desktop.dap.is_active():
                    desktop.dap.client.process.trace(
                        String("iter ") + String(iter_n)
                        + String(" before-refresh_size"),
                    )
                var resized = app.terminal.refresh_size()
                if desktop.dap.is_active():
                    desktop.dap.client.process.trace(
                        String("iter ") + String(iter_n)
                        + String(" after-refresh_size resized=")
                        + (String("True") if resized else String("False"))
                        + String(" w=") + String(app.terminal.width)
                        + String(" h=") + String(app.terminal.height),
                    )
                var maybe_ev: Optional[Event]
                if resized:
                    if desktop.dap.is_active():
                        desktop.dap.client.process.trace(
                            String("iter ") + String(iter_n)
                            + String(" before-back-resize"),
                        )
                    app.back.resize(app.terminal.width, app.terminal.height)
                    if desktop.dap.is_active():
                        desktop.dap.client.process.trace(
                            String("iter ") + String(iter_n)
                            + String(" after-back-resize"),
                        )
                    maybe_ev = Optional[Event](Event.resize_event(
                        app.terminal.width, app.terminal.height,
                    ))
                else:
                    if desktop.dap.is_active():
                        desktop.dap.client.process.trace(
                            String("iter ") + String(iter_n)
                            + String(" before-poll_event"),
                        )
                    maybe_ev = app.terminal.poll_event(50)
                    if desktop.dap.is_active():
                        desktop.dap.client.process.trace(
                            String("iter ") + String(iter_n)
                            + String(" after-poll_event"),
                        )
                    # The native wrapper pushes ``CSI 8 ; rows ; cols t``
                    # on resize; ``poll_event`` parses it and returns an
                    # ``EVENT_RESIZE`` with ``terminal.width/height``
                    # already updated. We have to mirror that into the
                    # back canvas here — ``refresh_size`` is short-
                    # circuited by ``poll_stdin`` whenever the wrapper's
                    # bytes are still pending, so its ``True`` branch
                    # above never gets a chance to do the resize on the
                    # wrapper path.
                    if maybe_ev:
                        var pe = maybe_ev.value()
                        if pe.kind == EVENT_RESIZE:
                            app.back.resize(
                                app.terminal.width, app.terminal.height,
                            )
                desktop.lsp_tick(app.screen())
                desktop.dap_tick(app.screen())
                if not maybe_ev:
                    continue
                var ev = maybe_ev.value()
                if desktop.dap.is_active():
                    desktop.dap.client.process.trace(
                        String("iter ") + String(iter_n)
                        + String(" before-handle_event kind=")
                        + String(Int(ev.kind)),
                    )

                # Hint a text-cursor / arrow-cursor to the host based
                # on what's under the mouse. Generic terminals ignore
                # the OSC; the bundled native app picks it up and calls
                # ``winit::Window::set_cursor``.
                if ev.kind == EVENT_MOUSE and not file_dialog.active:
                    try:
                        app.terminal.set_pointer_shape(
                            desktop.pointer_shape_at(ev.pos, app.screen()),
                        )
                    except:
                        pass

                # Modal: file dialog eats every event while open.
                if file_dialog.active:
                    if ev.kind == EVENT_KEY:
                        _ = file_dialog.handle_key(ev)
                    else:
                        _ = file_dialog.handle_mouse(ev, app.screen())
                    if file_dialog.submitted:
                        var path = file_dialog.selected_path
                        file_dialog.close()
                        try:
                            desktop.open_file(path, app.screen())
                        except:
                            pass
                    continue

                var maybe_action = desktop.handle_event(ev, app.screen())
                if maybe_action:
                    var action = maybe_action.value()
                    if action == APP_QUIT_ACTION:
                        # Stamp the trace log so we know exit was triggered
                        # by an action (Ctrl+Q, menu Quit, etc.) rather than
                        # a Mojo-side crash that took the process down.
                        desktop.dap.client.process.trace(
                            String("APP_QUIT_ACTION fired"),
                        )
                        app.quit()
                    elif action == String("file:open"):
                        file_dialog.open(String("."))
                    elif action == EDITOR_QUICK_OPEN:
                        file_dialog.open(String("."))
                    elif action == String("focus:About"):
                        desktop.windows.focus_by_title(String("About"))
            except e:
                # Any uncaught raise lands here. Stamp the trace log
                # AND the error_log so something is visible after exit
                # whether the user looks at /tmp/turbokod-dap.log or
                # the post-stop print. We continue rather than break so
                # a transient terminal hiccup (e.g. one bad cursor-size
                # response) doesn't kill the whole session.
                var msg = String("frame raised: ") + String(e)
                error_log.append(msg)
                if desktop.dap.is_active():
                    desktop.dap.client.process.trace(msg)
        # Reap the LSP child before we leave the try block — ``desktop`` isn't
        # in scope from the outer ``finally``, and we'd rather not orphan the
        # subprocess if the loop exits cleanly via Ctrl+Q.
        for i in range(len(desktop.lsp_managers)):
            desktop.lsp_managers[i].shutdown()
        desktop.dap.shutdown()
        app.stop()
        for i in range(len(error_log)):
            print(error_log[i])
        # Consume so the ``finally`` backup doesn't double-print on
        # the clean-exit path.
        error_log = List[String]()
    finally:
        # Backup for the exception path: ``app.stop`` is idempotent,
        # so it's a no-op when the clean path already ran.
        app.stop()
        for i in range(len(error_log)):
            print(error_log[i])
