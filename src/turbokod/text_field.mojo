"""Single-line text-field helpers shared by every dialog that has an
editable input strip (``Prompt``, ``QuickOpen``, ``SaveAsDialog``,
``SymbolPick``, ``DocPick``, ``ProjectFind``, ``TargetsDialog``).

The dialogs all keep their own ``String`` slot for the field value plus
their own dialog-specific bookkeeping (refilter, dirty-mark, …). This
module supplies the missing piece they all needed — system-clipboard
cut / copy / paste — without forcing them to share a widget struct or
adopt an internal cursor model. Each dialog calls
``text_field_clipboard_key`` near the top of its ``handle_key`` and
inspects the returned flags to decide whether to refresh derived state.

Single-line semantics: paste filters out CR / LF / TAB so a multi-line
clipboard payload doesn't smuggle real newlines into a one-row strip,
and replacement chars (0x00..0x1F other than the ones we drop) are
ignored. Cut copies the whole field to the clipboard before clearing
it — there's no internal selection model to honour, and "cut keeps the
caret position" matches the way users intuit a one-shot Ctrl+X on a
form field.
"""

from .clipboard import clipboard_copy, clipboard_paste
from .events import EVENT_KEY, Event


@fieldwise_init
struct TextFieldKeyResult(Copyable, Movable):
    """Outcome of ``text_field_clipboard_key``.

    ``consumed`` — True if the helper handled the event; the caller
    should ``return True`` from its own ``handle_key`` and skip its
    normal printable / backspace branches.

    ``changed`` — True if the field's text was mutated. Callers that
    derive state from the field (filter results, dirty markers,
    debouncers) should refresh on True; pure-copy events leave the
    field untouched and report False.
    """
    var consumed: Bool
    var changed: Bool


fn text_field_clipboard_key(
    event: Event, mut text: String,
) -> TextFieldKeyResult:
    """Apply Ctrl+C / Ctrl+X / Ctrl+V to a single-line ``text`` field.

    The control codepoints (0x03, 0x18, 0x16) are what every common
    terminal delivers for those chords; ``MOD_CTRL`` is *not* set on
    the event because the parser folds the control byte into ``key``.
    Returns a ``TextFieldKeyResult`` so the caller can branch on
    consumed-vs-changed without re-checking the keystroke.
    """
    if event.kind != EVENT_KEY:
        return TextFieldKeyResult(False, False)
    var k = event.key
    if k == UInt32(0x03):    # Ctrl+C — copy whole field
        clipboard_copy(text)
        return TextFieldKeyResult(True, False)
    if k == UInt32(0x18):    # Ctrl+X — copy then clear
        clipboard_copy(text)
        var had_text = len(text.as_bytes()) > 0
        text = String("")
        return TextFieldKeyResult(True, had_text)
    if k == UInt32(0x16):    # Ctrl+V — append clipboard at end
        var pasted = _sanitize_single_line(clipboard_paste())
        if len(pasted.as_bytes()) == 0:
            return TextFieldKeyResult(True, False)
        text = text + pasted
        return TextFieldKeyResult(True, True)
    return TextFieldKeyResult(False, False)


fn _sanitize_single_line(text: String) -> String:
    """Strip CR / LF / TAB and other control bytes from a paste payload.

    A clipboard chunk with embedded newlines would otherwise smuggle
    real ``\\n`` bytes into a single-row input strip — the ``put_text``
    paint path doesn't render them and the dialog's submit logic
    wouldn't expect them either. Tabs are dropped for the same reason
    (the strip has no tabstop model). Printable bytes >= 0x20 and
    valid-looking UTF-8 continuation bytes (>= 0x80) are preserved so
    a paste of e.g. ``café`` survives.
    """
    var b = text.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        var byte = b[i]
        # Drop the C0 control range (and DEL) outright. ``put_text``
        # treats them as one-cell glyphs but most of them have no
        # rendering at all, so silently dropping is friendlier than
        # painting boxes.
        if byte < 0x20 or byte == 0x7F:
            continue
        out.append(byte)
    if len(out) == 0:
        return String("")
    return String(StringSlice(ptr=out.unsafe_ptr(), length=len(out)))
