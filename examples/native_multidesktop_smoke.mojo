"""Proof that two independent Desktops render in two native windows.

The interactive demo (desktop_native.mojo) spawns the 2nd window on Cmd+N /
File ▸ New window, which can't be synthesized headlessly — so here we open
the second window directly, give each window its own Desktop showing a
different file, paint a few frames, and capture both framebuffers.
"""

from std.collections.list import List
from std.memory import ArcPointer

from turbokod import (
    APP_QUIT_ACTION, APP_SETTINGS, Canvas, Desktop, Menu, MenuItem, Rect,
    EDITOR_NEW, EDITOR_OPEN, default_attr,
)
from turbokod.native_window import NativeApp, NativeWindow


def _make_desktop() raises -> Desktop:
    var d = Desktop()
    d.load_config_from_disk()
    var ham = List[MenuItem]()
    ham.append(MenuItem(String("Settings"), APP_SETTINGS))
    ham.append(MenuItem.separator())
    ham.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    d.menu_bar.add(Menu(String("≡"), ham^, is_system=True))
    var f = List[MenuItem]()
    f.append(MenuItem(String("New"), EDITOR_NEW))
    f.append(MenuItem(String("New window"), String("app.new_window")))
    f.append(MenuItem(String("Open..."), EDITOR_OPEN))
    d.menu_bar.add(Menu(String("File"), f^))
    return d^


def _frame(mut win: NativeWindow, mut d: Desktop):
    win.sync_size()
    var s = Rect(0, 0, win.width, win.height)
    var c = Canvas(win.width, win.height)
    c.clear(default_attr())
    d.paint(c, s)
    win.present(c)
    d.lsp_tick(s)


def main() raises:
    var app = NativeApp()
    app.start()
    var w1 = app.open_window()
    w1.set_title(String("TurboKod — window 1"))
    var w2 = app.open_window()
    w2.set_title(String("TurboKod — window 2"))

    var d1 = ArcPointer(_make_desktop())
    var d2 = ArcPointer(_make_desktop())
    try:
        d1[].open_file(String("src/turbokod/cell.mojo"), Rect(0, 0, w1.width, w1.height))
    except e:
        print("w1 open:", String(e))
    try:
        d2[].open_file(String("src/turbokod/colors.mojo"), Rect(0, 0, w2.width, w2.height))
    except e:
        print("w2 open:", String(e))

    for _ in range(18):
        _frame(w1, d1[])
        _frame(w2, d2[])
        app.pump(20)
        var ev = app.next_event()
        while ev:
            ev = app.next_event()

    var ok1 = w1.capture_bmp(String("/tmp/md1.bmp"))
    var ok2 = w2.capture_bmp(String("/tmp/md2.bmp"))
    print("two desktops rendered; window_count =", app.window_count(),
          "captures:", ok1, ok2)

    for i in range(len(d1[].lsp_managers)):
        d1[].lsp_managers[i].shutdown()
    for i in range(len(d2[].lsp_managers)):
        d2[].lsp_managers[i].shutdown()
    app.stop()
