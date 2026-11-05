# Attention pings: the badge and the outline

A **ping** is something in a tool pane that wants the user: a Claude session
in a terminal pane finishing its turn or asking for permission
(`TerminalPane._note_claude_state`), or the debugger stopping (`dap_tick`).

## Unseen until its window is looked at

A ping isn't "seen" when the app comes to the front — only when the window
it came from does. Each one lands on its origin pane's
`BottomDockedPanel.attention_unseen` when the host drains it
(`Desktop.take_attention_events`), and stays there until the host calls
`Desktop.mark_attention_seen`:

- **Native app.** Every tick `drainAttention` drains each project Desktop;
  a project whose window (main or floating panels) is key in the active app
  sees its pings at once (`flash=0`). The Dock badge is the sum of
  `tk_desktop_attention_unseen` over the projects, so activating the app on
  another project leaves it up. A fresh ping while the app is in the
  background also bounces the Dock icon. `NSWindow.didBecomeKeyNotification`
  (`attentionWindowBecameKey`) sees a project's pings with `flash=1`.
- **Terminal frontends.** A ping while the terminal has the focus is seen at
  once; one while it doesn't rings the bell (`Terminal.bell`, which most
  terminals turn into a Dock bounce / badge or a tab marker). The focus-in
  report (`EVENT_FOCUS_IN`, forwarded by `tk-tui` through
  `tk_desktop_focus`) sees them with a flash. `handle_event` also tracks
  `host_focused` from those reports. A terminal that sends no focus reports
  counts as always focused: its pings are seen at once and never ring.

## The outline

Seeing a ping with `flash` sets the pane's `flash_start_ms`; for
`ATTENTION_FLASH_MS` (1 s) the pane is outlined, fading out
(`Desktop.attention_flashes` lists the live ones per surface, docked or
floating). Each look draws it its own way:

- **macOS look**: `AttentionFlashView`, a rounded accent-colored ring over
  the pane, opacity eased out by Core Animation.
- **Mac OS 9 look**: the same view drawing a square Platinum ring (black,
  accent, lavender) that steps out in discrete opacity steps.
- **Turbo Vision look and the terminals**: in cells
  (`paint_attention_outline`): the pane's perimeter retinted toward the
  theme's bright yellow in truecolor, the header row's text pulled toward
  black to stay legible, eased in (`attention_flash_strength`) so it holds
  and then falls away.

The core reports the outlines to the host (`tk_desktop_attention_flashes`)
only when the host draws the pane chrome (`host_pane_headers()`), and paints
them itself otherwise — so exactly one of the two draws.
