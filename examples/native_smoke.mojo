"""Non-interactive smoke test for the native frontend.

Verifies the whole FFI pipeline without needing eyes on a window:
creates the window, reports the size the C ABI round-trips back, presents
a frame, pumps the event loop a few times, then exits cleanly. Run with::

    ./run_native.sh examples/native_smoke.mojo
"""

from turbokod.native_window import NativeFrontend
from turbokod.canvas import Canvas
from turbokod.colors import Attr, BLUE, WHITE, YELLOW
from turbokod.geometry import Point


def main() raises:
    var fe = NativeFrontend()
    fe.start()
    print("created window; size =", fe.width, "x", fe.height)
    if fe.width <= 0 or fe.height <= 0:
        print("FAIL: window size is non-positive")
        fe.stop()
        return

    fe.set_title(String("turbokod smoke"))

    var total_events = 0
    for frame in range(10):
        var back = Canvas(fe.width, fe.height)
        back.clear(Attr(WHITE, BLUE))
        _ = back.put_text(Point(2, 1),
            String("native smoke frame ") + String(frame), Attr(YELLOW, BLUE))
        fe.present(back)
        var ev = fe.poll_event(30)
        while ev:
            total_events += 1
            ev = fe.poll_event(0)

    print("presented 10 frames; pumped", total_events, "events; no crash")

    # Capture the last presented frame to a BMP so rendering can be
    # verified without Screen Recording permission.
    var ok = fe.capture_bmp(String("/tmp/native_smoke.bmp"))
    print("capture_bmp ok =", ok)

    fe.stop()
    print("stopped cleanly")
