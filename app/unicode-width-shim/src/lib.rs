//! Override of the upstream `unicode-width` crate that returns `Some(1)` for
//! every codepoint that isn't a C0/C1 control character.
//!
//! Why: alacritty_terminal calls `c.width()` to decide whether a glyph takes
//! one or two terminal cells. Wide codepoints (emoji, CJK) produce a
//! `WIDE_CHAR` cell plus a `WIDE_CHAR_SPACER` cell, which conflicts with
//! turbokod's "one codepoint = one canvas column" model — the wrapper's
//! grid drifts +1 column past every wide char and stale cells leak through
//! when content moves. Forcing every printable codepoint to width 1 keeps
//! the grids aligned: emoji still get drawn at full visual fidelity by our
//! atlas, but the alacritty grid no longer interleaves spacer cells.
//!
//! This is a deliberate departure from terminal-correct behavior. The wrapper
//! is a single-purpose UI for turbokod, not a general-purpose terminal —
//! we own the renderer end-to-end and pay no penalty for ignoring East Asian
//! Width.


#[doc(hidden)]
pub const UNICODE_VERSION: (u64, u64, u64) = (16, 0, 0);

mod private {
    pub trait Sealed {}
    impl<T: ?Sized> Sealed for T {}
}

#[inline]
fn one_for_printable(c: char) -> Option<usize> {
    // Match the upstream contract: control chars (C0 0x00..0x1F minus 0x09/0x0A/0x0D
    // are still typically zero-width per UAX #11; we keep the convention of
    // returning None for the C0/C1 ranges so callers that care about "is this
    // a control character?" don't get tricked).
    let cp = c as u32;
    if cp < 0x20 || (0x7F..=0x9F).contains(&cp) {
        return None;
    }
    Some(1)
}

pub trait UnicodeWidthChar: private::Sealed {
    fn width(self) -> Option<usize>;
    #[cfg(feature = "cjk")]
    fn width_cjk(self) -> Option<usize>;
}

impl UnicodeWidthChar for char {
    #[inline]
    fn width(self) -> Option<usize> {
        one_for_printable(self)
    }
    #[cfg(feature = "cjk")]
    #[inline]
    fn width_cjk(self) -> Option<usize> {
        one_for_printable(self)
    }
}

pub trait UnicodeWidthStr: private::Sealed {
    fn width(&self) -> usize;
    #[cfg(feature = "cjk")]
    fn width_cjk(&self) -> usize;
}

impl UnicodeWidthStr for str {
    #[inline]
    fn width(&self) -> usize {
        // Sum of per-codepoint widths, treating control characters as 0.
        self.chars().map(|c| one_for_printable(c).unwrap_or(0)).sum()
    }
    #[cfg(feature = "cjk")]
    #[inline]
    fn width_cjk(&self) -> usize {
        self.width()
    }
}
