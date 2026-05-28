"""Verify the system clipboard round-trips from a native (non-TTY) process.

The Desktop's copy/paste goes through clipboard.mojo (pbcopy/pbpaste via
popen), which is frontend-independent — it works the same whether driven by
Terminal or NativeFrontend. This confirms it end to end.
"""

from turbokod.clipboard import clipboard_copy, clipboard_paste


def main():
    var sent = String("turbokod native clipboard ✓ 123")
    clipboard_copy(sent)
    var got = clipboard_paste()
    print("sent:", sent)
    print("got :", got)
    if got == sent:
        print("CLIPBOARD ROUND-TRIP OK")
    else:
        print("CLIPBOARD MISMATCH")
