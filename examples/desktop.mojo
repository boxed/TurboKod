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

from turbokod.app_menus import build_menus, refresh_menu_visibility
from turbokod.string_utils import split_open_arg
from turbokod import (
    APP_QUIT_ACTION, Application, Event, Desktop, FileDialog, EDITOR_OPEN,
    EDITOR_QUICK_OPEN, EVENT_KEY, EVENT_MOUSE, EVENT_OPEN_PATH, EVENT_RESIZE,
    PROJECT_OPEN, stat_file,
)


def main() raises:
    var app = Application()
    var error_log = List[String]()        # populated in the loop, drained on quit
    app.start()
    try:
        var desktop = Desktop()
        desktop.load_config_from_disk()
        # Push the active theme's palette so the terminal's truecolor renderer
        # paints the theme (not the user's terminal scheme). Re-pushed in the
        # loop whenever the user switches theme in Settings.
        app.set_palette(desktop.active_theme.palette)
        var last_theme_version = desktop.theme_version
        var file_dialog = FileDialog()

        build_menus(desktop, native=False)
        # The "Window" menu is owned by Desktop and rebuilt every frame from
        # the actual window list — host doesn't add one.

        # Cmd-line args open files / projects. A directory arg is
        # treated as a project root (no file opened); a regular file
        # is opened as an editor window the usual way. With no args
        # the desktop comes up empty — the user opens files via F3 or
        # the Project menu, and ``_set_project`` then arms the
        # session restore.
        # The native wrapper translates ``turbokod://open?file=X&line=N``
        # URLs into ``<path>\x1f<line>`` strings before passing them on,
        # so the loop only ever sees a real filesystem path with an
        # optional jump-line suffix.
        var args = argv()
        for i in range(1, len(args)):
            var raw = String(args[i])
            var parsed = split_open_arg(raw)
            var path = parsed[0]
            var line = parsed[1]
            var info = stat_file(path)
            if info.ok and info.is_dir():
                desktop.open_project(path)
                continue
            try:
                if line > 0:
                    desktop.open_file_at(
                        path, line - 1, 0, app.screen(),
                    )
                else:
                    desktop.open_file(path, app.screen())
            except e:
                error_log.append(
                    String("open ") + path + String(": ") + String(e),
                )

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
                    desktop.process_external_changes(app.screen())
                except e:
                    error_log.append(String("reload: ") + String(e))
                refresh_menu_visibility(desktop)
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
                # Re-push the palette if the user switched theme this frame
                # (Settings applies it via Desktop.set_theme, bumping the
                # version). Cheap to skip when unchanged.
                if desktop.theme_version != last_theme_version:
                    app.set_palette(desktop.active_theme.palette)
                    last_theme_version = desktop.theme_version
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
                desktop.terminal_tick()
                desktop.save_actions_tick()
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

                # Path forwarded from a second wrapper invocation. Same
                # treatment as a startup argv entry — directory ⇒ project
                # root, regular file ⇒ editor window, anything that
                # doesn't stat is silently ignored. The wrapper carries
                # an optional jump-line in ``ev.pos.y`` (1-based) when
                # the original argument was a ``turbokod://open?...&line=N``
                # URL.
                if ev.kind == EVENT_OPEN_PATH:
                    var path = ev.text
                    if path.byte_length() > 0:
                        var info = stat_file(path)
                        if info.ok and info.is_dir():
                            desktop.open_project(path)
                        else:
                            try:
                                var line = ev.pos.y
                                if line > 0:
                                    desktop.open_file_at(
                                        path, line - 1, 0, app.screen(),
                                    )
                                else:
                                    desktop.open_file(path, app.screen())
                            except e:
                                error_log.append(
                                    String("open ") + path + String(": ")
                                    + String(e),
                                )
                    continue

                # Modal: file dialog eats every event while open.
                if file_dialog.active:
                    if ev.kind == EVENT_KEY:
                        _ = file_dialog.handle_key(ev)
                    else:
                        _ = file_dialog.handle_mouse(ev, app.screen())
                    if file_dialog.submitted:
                        var path = file_dialog.selected_path
                        var picks_project = file_dialog.dirs_only
                        file_dialog.close()
                        if picks_project:
                            # Project switch: close any current project so
                            # ``open_project``'s "no-op when one is set"
                            # guard doesn't swallow the request.
                            if desktop.project:
                                desktop.close_project()
                            desktop.open_project(path)
                        else:
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
                        # Stop any debug / run session before we leave the
                        # loop so the child gets SIGTERM (and, for DAP, the
                        # adapter's ``disconnect`` with ``terminateDebuggee``)
                        # while we still have its pid in hand. Cleanup below
                        # is a defensive backstop; this is the path the user
                        # actually triggers. We don't bother clearing the
                        # gutter exec marker — the screen is about to go.
                        if desktop.dap.is_active():
                            desktop.dap.shutdown()
                        if desktop.run_session.is_active():
                            desktop.run_session.terminate()
                        app.quit()
                    elif action == EDITOR_OPEN:
                        var start = desktop.project.value() \
                            if desktop.project else String(".")
                        file_dialog.open(start)
                        file_dialog.set_project(desktop.project)
                    elif action == EDITOR_QUICK_OPEN:
                        var start = desktop.project.value() \
                            if desktop.project else String(".")
                        file_dialog.open(start)
                        file_dialog.set_project(desktop.project)
                    elif action == PROJECT_OPEN:
                        # Directory-pick mode: the user navigates to the
                        # project root and clicks " Open Project " (or
                        # ESC to cancel). Submission goes through the
                        # ``picks_project`` branch above.
                        var start = desktop.project.value() \
                            if desktop.project else String(".")
                        file_dialog.open_directory(start)
                        file_dialog.set_project(desktop.project)
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
        # Reap any spawned children before we leave the try block —
        # ``desktop`` isn't in scope from the outer ``finally``, and we'd
        # rather not orphan a subprocess if the loop exits cleanly via
        # Ctrl+Q. The action handler above already stops dap / run on the
        # quit path; these calls are idempotent backstops for any other
        # path out of the loop.
        for i in range(len(desktop.lsp_managers)):
            desktop.lsp_managers[i].shutdown()
        desktop.dap.shutdown()
        desktop.run_session.terminate()
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
