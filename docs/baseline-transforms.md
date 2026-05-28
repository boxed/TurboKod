# Baseline-driven reversible transforms

For UI transforms the user is likely to round-trip (terminal resize, window resize, anything they may undo), scale from a **stored baseline + reference state** — not from the current value.

## Why

Naive proportional scaling rounds each rect on every transform. Shrink-then-grow accumulates rounding error and ends at e.g. 49 / 51 cells instead of 50 / 50. Two side-by-side ~50% windows become asymmetric after the user resizes the terminal down and back up. Round-trips must be lossless.

## Pattern

When implementing a transform over integer-coordinate state:

1. **Capture a baseline at the moment of user intent** — the value plus the reference dimensions at the time.
2. **Re-derive each subsequent state from that baseline**, not from the previous frame's result.
3. **Rebase the baseline only when a user action mutates the value.** Detect this by comparing against a `_last_observed_*` snapshot from the previous frame. Don't rebase during a transform — that's what reintroduces the rounding loss.

## Reference implementation

In `WindowManager.fit_into` / `Window._baseline_rect` / `_last_observed_rect`. New code that does similar transforms over integer coordinates should follow that pattern.
