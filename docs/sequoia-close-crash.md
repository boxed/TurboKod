# Sequoia AppKit close-window crash

## Symptom

On macOS Sequoia (Darwin 24.x), closing a window via `NSWindow.performClose(_:)` or `.close()` segfaults the app on the *next* runloop turn. Exit code 139. Reproducible regardless of whether it's the last window — it fires on *any* close.

## Stack

```
objc_release
AutoreleasePoolPage::releaseUntil
objc_autoreleasePoolPop
_CFAutoreleasePoolPop
__CFRunLoopPerCalloutARPEnd
__CFRunLoopRun
…
```

`EXC_BAD_ACCESS` releasing an object at ~`0x20`. Reproducible in a *stub* Swift app with one empty `NSWindow`, no custom views, no delegate — i.e. AppKit's own teardown is broken, not user code.

Independent repro:

```swift
import AppKit
final class C: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_:Notification) {
    let w = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:300),
                     styleMask:[.titled,.closable],backing:.buffered,defer:false)
    w.makeKeyAndOrderFront(nil)
    DispatchQueue.main.asyncAfter(deadline:.now()+0.8){w.performClose(nil)}
  }
}
let a=NSApplication.shared; a.setActivationPolicy(.regular)
let c=C(); a.delegate=c; a.run()
```

→ exit 139 on Sequoia. Same code with `NSApp.terminate(nil)` instead → exit 0.

## Workaround

Intercept at `windowShouldClose(_:)` — which runs **before** AppKit starts the broken cascade — do all cleanup + `orderOut`, return `false` so AppKit skips the teardown entirely.

```swift
func windowShouldClose(_ sender: NSWindow) -> Bool {
    // Drop our references / free Mojo state…
    sender.orderOut(nil)
    return false
}
```

`windowWillClose(_:)` is intentionally *not* implemented — returning `false` from `shouldClose` means it never fires.

The cost: the `NSWindow` object stays in `NSApp.windows` (we order-out instead of releasing). On a long session with many close/reopen cycles this leaks a few KB per window — acceptable vs. crashing on every close.

## Notes

- `NSApp.terminate(nil)` (Cmd+Q) is **not affected**. That path calls `applicationShouldTerminate` → `_exit`, skipping per-window close cascade. Keep using it.
- `closeWindow(_ view:)` in `AppController` calls `performClose(nil)` (not `.close()`) so it routes through `windowShouldClose`. Using `.close()` would bypass `shouldClose` and trigger the same bug.
- `applicationShouldTerminateAfterLastWindowClosed` returns `false` — the app stays alive when no windows are open. The user re-opens via the menu; Cmd+Q is the only quit path.

See `app/swift/TurboKod.swift::windowShouldClose` for the live workaround.
