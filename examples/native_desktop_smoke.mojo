"""Non-interactive proof that the real Desktop renders in the native window.

Opens a source file (so syntax highlighting is exercised), paints a handful
of frames, dumps the framebuffer to /tmp/native_desktop.bmp, and exits.
Run with::  ./run_native.sh examples/native_desktop_smoke.mojo
"""

from std.collections.list import List

from turbokod import (
    Canvas, Desktop, FileDialog, Menu, MenuItem, Rect,
    APP_QUIT_ACTION, APP_SETTINGS,
    EDITOR_NEW, EDITOR_OPEN, EDITOR_SAVE,
    default_attr,
)
from turbokod.native_window import NativeFrontend


def main() raises:
    var fe = NativeFrontend()
    fe.start()
    fe.set_title(String("TurboKod (native desktop smoke)"))

    var desktop = Desktop()
    desktop.load_config_from_disk()

    # A small menu bar so the shot shows the chrome, not just an editor.
    var ham = List[MenuItem]()
    ham.append(MenuItem(String("Settings"), APP_SETTINGS))
    ham.append(MenuItem.separator())
    ham.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    desktop.menu_bar.add(Menu(String("≡"), ham^, is_system=True))
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), EDITOR_NEW))
    file_items.append(MenuItem(String("Open..."), EDITOR_OPEN))
    file_items.append(MenuItem(String("Save"), EDITOR_SAVE))
    desktop.menu_bar.add(Menu(String("File"), file_items^))

    var screen = Rect(0, 0, fe.width, fe.height)
    try:
        desktop.open_file(String("src/turbokod/cell.mojo"), screen)
    except e:
        print("open_file failed:", String(e))

    var back = Canvas(fe.width, fe.height)
    for _ in range(20):
        if back.width != fe.width or back.height != fe.height:
            back.resize(fe.width, fe.height)
        screen = Rect(0, 0, back.width, back.height)
        back.clear(default_attr())
        desktop.paint(back, screen)
        fe.present(back)
        var ev = fe.poll_event(20)
        while ev:
            ev = fe.poll_event(0)

    var ok = fe.capture_bmp(String("/tmp/native_desktop.bmp"))
    print("desktop rendered; capture ok =", ok, "size =", fe.width, "x", fe.height)

    for i in range(len(desktop.lsp_managers)):
        desktop.lsp_managers[i].shutdown()
    desktop.dap.shutdown()
    fe.stop()
