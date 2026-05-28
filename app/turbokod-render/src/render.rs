//! Glyph rasterization + cell painting.
//!
//! Lifted almost verbatim from `app/src/main.rs` (the alacritty-backed
//! wrapper's renderer). The only behavioral change vs. that code is the
//! cell *source*: there, cells came from alacritty's grid; here they come
//! from a buffer the Mojo side pushes through the C ABI (see `lib.rs`).
//! The atlas, fontdue raster path, Core Text fallback, blend, palette, and
//! shade-dither are unchanged so the native frontend looks pixel-identical
//! to the terminal-backed one.

use std::collections::HashMap;

use fontdue::{Font, FontSettings};

// Px437_IBM_VGA_8x16.ttf is a pixel-perfect recreation of the IBM VGA ROM
// font with an 8 wide × 16 tall cell.
pub const CELL_W_BASE: u32 = 8;
pub const CELL_H_BASE: u32 = 16;
const RASTER_PX: f32 = 16.0;
const FALLBACK_PX: f32 = 13.0;

pub const DEFAULT_FG: u32 = 0xC0_C0_C0;
pub const DEFAULT_BG: u32 = 0x00_00_00;

// Shared with the lib.rs ABI: the font asset lives at app/assets, two
// directories up from this crate's src/.
const PX437: &[u8] = include_bytes!("../../assets/Px437_IBM_VGA_8x16.ttf");

const FALLBACK_FONTS: &[(&str, u32)] = &[
    ("/System/Library/Fonts/Menlo.ttc", 0),
    ("/System/Library/Fonts/Monaco.ttf", 0),
    ("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 0),
];

#[derive(Copy, Clone, PartialEq, Eq, Hash)]
pub enum UnderlineKind {
    None,
    Plain,
    Curly,
}

#[derive(Copy, Clone)]
pub struct RenderCell {
    pub c: char,
    pub fg: u32,
    pub bg: u32,
    pub underline: UnderlineKind,
    pub underline_color: u32,
}

// Coverage glyphs use a single byte per pixel and get blended against the
// cell's fg/bg colors at paint time. Color glyphs (currently emoji only)
// carry premultiplied ARGB so the original colors come through.
enum AtlasGlyph {
    Coverage(Vec<u8>),
    Color(Vec<u32>),
}

pub struct Atlas {
    primary: Font,
    primary_baseline: i32,
    fallback: Option<Font>,
    fallback_baseline: i32,
    glyphs: HashMap<char, AtlasGlyph>,
    scale: u32,
}

impl Atlas {
    pub fn new(scale: u32) -> Self {
        let primary = Font::from_bytes(PX437, FontSettings::default()).unwrap();
        let primary_baseline =
            primary.horizontal_line_metrics(RASTER_PX).unwrap().ascent.round() as i32;
        let (fallback, fallback_baseline) = load_fallback_font();
        Self {
            primary,
            primary_baseline,
            fallback,
            fallback_baseline,
            glyphs: HashMap::new(),
            scale,
        }
    }

    pub fn cell_w(&self) -> u32 {
        CELL_W_BASE * self.scale
    }
    pub fn cell_h(&self) -> u32 {
        CELL_H_BASE * self.scale
    }

    fn glyph(&mut self, ch: char) -> &AtlasGlyph {
        let scale = self.scale;
        let primary = &self.primary;
        let primary_baseline = self.primary_baseline;
        let fallback = self.fallback.as_ref();
        let fallback_baseline = self.fallback_baseline;
        self.glyphs.entry(ch).or_insert_with(|| {
            if primary.has_glyph(ch) {
                AtlasGlyph::Coverage(rasterize(primary, ch, scale, primary_baseline, RASTER_PX, false))
            } else if fallback.map_or(false, |f| f.has_glyph(ch)) {
                AtlasGlyph::Coverage(rasterize(fallback.unwrap(), ch, scale, fallback_baseline, FALLBACK_PX, true))
            } else if let Some(g) = os_fallback_rasterize(ch, scale) {
                g
            } else {
                AtlasGlyph::Coverage(vec![0u8; (CELL_W_BASE * scale * CELL_H_BASE * scale) as usize])
            }
        })
    }
}

fn load_fallback_font() -> (Option<Font>, i32) {
    for (path, idx) in FALLBACK_FONTS {
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(_) => continue,
        };
        let mut settings = FontSettings::default();
        settings.collection_index = *idx;
        let Ok(font) = Font::from_bytes(bytes, settings) else { continue };
        let Some(metrics) = font.horizontal_line_metrics(FALLBACK_PX) else { continue };
        return (Some(font), metrics.ascent.round() as i32);
    }
    (None, 0)
}

#[cfg(not(target_os = "macos"))]
fn os_fallback_rasterize(_ch: char, _scale: u32) -> Option<AtlasGlyph> {
    None
}

// macOS Core Text fallback: hand the OS a one-character string and ask it
// to substitute whatever font can actually render the codepoint, then draw
// into a bitmap the atlas treats like any other rasterized glyph.
#[cfg(target_os = "macos")]
fn os_fallback_rasterize(ch: char, scale: u32) -> Option<AtlasGlyph> {
    use core_foundation::attributed_string::CFMutableAttributedString;
    use core_foundation::base::{CFRange, TCFType};
    use core_foundation::string::{CFString, CFStringRef};
    use core_graphics::base::{kCGImageAlphaPremultipliedLast, kCGBitmapByteOrderDefault};
    use core_graphics::color_space::CGColorSpace;
    use core_graphics::context::CGContext;
    use core_text::font::{kCTFontSystemFontType, new_ui_font_for_language, CTFont, CTFontRef};
    use core_text::line::CTLine;
    use core_text::string_attributes;

    let cell_w = (CELL_W_BASE * scale) as usize;
    let cell_h = (CELL_H_BASE * scale) as usize;

    let s = CFString::new(&ch.to_string());
    let mut pt_size = (CELL_H_BASE * scale) as f64;
    let base_font = new_ui_font_for_language(kCTFontSystemFontType, pt_size, None);

    extern "C" {
        fn CTFontCreateForString(f: CTFontRef, s: CFStringRef, r: CFRange) -> CTFontRef;
    }
    let full = CFRange::init(0, s.char_len());
    let resolved = unsafe {
        let raw =
            CTFontCreateForString(base_font.as_concrete_TypeRef(), s.as_concrete_TypeRef(), full);
        if raw.is_null() {
            return None;
        }
        CTFont::wrap_under_create_rule(raw)
    };
    let family = resolved.family_name();
    let is_emoji = family.contains("Emoji");
    if is_emoji {
        pt_size = (CELL_W_BASE * scale) as f64;
    }
    let render_font = resolved.clone_with_font_size(pt_size);

    let cs = CGColorSpace::create_device_rgb();
    let bytes_per_row = cell_w * 4;
    let bitmap_info = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault;
    let mut ctx =
        CGContext::create_bitmap_context(None, cell_w, cell_h, 8, bytes_per_row, &cs, bitmap_info);
    ctx.set_rgb_fill_color(1.0, 1.0, 1.0, 1.0);
    ctx.set_should_antialias(true);
    ctx.set_should_smooth_fonts(true);

    let mut attr = CFMutableAttributedString::new();
    attr.replace_str(&s, CFRange::init(0, 0));
    unsafe {
        attr.set_attribute(full, string_attributes::kCTFontAttributeName, &render_font);
    }
    let line = CTLine::new_with_attributed_string(attr.as_concrete_TypeRef());

    let bbox = line.get_image_bounds(&ctx);
    let dx = ((cell_w as f64 - bbox.size.width) / 2.0) - bbox.origin.x;
    let dy = ((cell_h as f64 - bbox.size.height) / 2.0) - bbox.origin.y;
    ctx.set_text_position(dx, dy);
    line.draw(&ctx);

    let bpr = ctx.bytes_per_row();
    let data = ctx.data();
    if is_emoji {
        let mut out = vec![0u32; cell_w * cell_h];
        let mut nonzero = false;
        for y in 0..cell_h {
            let src_start = y * bpr;
            for x in 0..cell_w {
                let off = src_start + x * 4;
                let r = data[off] as u32;
                let g = data[off + 1] as u32;
                let b = data[off + 2] as u32;
                let a = data[off + 3] as u32;
                if a != 0 {
                    nonzero = true;
                }
                out[y * cell_w + x] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
        if nonzero {
            Some(AtlasGlyph::Color(out))
        } else {
            None
        }
    } else {
        let mut out = vec![0u8; cell_w * cell_h];
        for y in 0..cell_h {
            let src_start = y * bpr;
            for x in 0..cell_w {
                out[y * cell_w + x] = data[src_start + x * 4 + 3];
            }
        }
        if out.iter().any(|&b| b != 0) {
            Some(AtlasGlyph::Coverage(out))
        } else {
            None
        }
    }
}

fn rasterize(font: &Font, ch: char, scale: u32, baseline: i32, px: f32, center: bool) -> Vec<u8> {
    let cell_w = CELL_W_BASE * scale;
    let cell_h = CELL_H_BASE * scale;
    let native = font_glyph(font, ch, baseline, px, center);
    if scale == 1 {
        return native;
    }
    let mut out = vec![0u8; (cell_w * cell_h) as usize];
    for y in 0..cell_h {
        let sy = y / scale;
        for x in 0..cell_w {
            let sx = x / scale;
            out[(y * cell_w + x) as usize] = native[(sy * CELL_W_BASE + sx) as usize];
        }
    }
    out
}

fn font_glyph(font: &Font, ch: char, baseline: i32, px: f32, center: bool) -> Vec<u8> {
    let mut native = vec![0u8; (CELL_W_BASE * CELL_H_BASE) as usize];
    if !font.has_glyph(ch) {
        return native;
    }
    let (m, bm) = font.rasterize(ch, px);
    if m.width == 0 || m.height == 0 {
        return native;
    }
    let bw = m.width as i32;
    let bh = m.height as i32;
    let top = baseline - bh - m.ymin;
    let left = if center {
        ((CELL_W_BASE as i32 - bw) / 2).max(0)
    } else {
        m.xmin.max(0)
    };
    for y in 0..bh {
        for x in 0..bw {
            let dx = left + x;
            let dy = top + y;
            if dx < 0 || dy < 0 || dx as u32 >= CELL_W_BASE || dy as u32 >= CELL_H_BASE {
                continue;
            }
            let src = bm[(y * bw + x) as usize];
            if src != 0 {
                native[(dy as u32 * CELL_W_BASE + dx as u32) as usize] = src;
            }
        }
    }
    native
}

#[inline]
fn blend(fg: u32, bg: u32, cov: u32) -> u32 {
    if cov == 0 {
        return bg;
    }
    if cov == 255 {
        return fg;
    }
    let inv = 255 - cov;
    let fr = (fg >> 16) & 0xFF;
    let fg_ = (fg >> 8) & 0xFF;
    let fb = fg & 0xFF;
    let br = (bg >> 16) & 0xFF;
    let bg_ = (bg >> 8) & 0xFF;
    let bb = bg & 0xFF;
    let r = (fr * cov + br * inv) / 255;
    let g = (fg_ * cov + bg_ * inv) / 255;
    let b = (fb * cov + bb * inv) / 255;
    (r << 16) | (g << 8) | b
}

fn shade_dither(c: char) -> Option<fn(i32, i32) -> bool> {
    match c {
        '\u{2591}' => Some(|x, y| ((x + 2 * y) & 3) == 3),
        '\u{2592}' => Some(|x, y| ((x + y) & 1) != 0),
        '\u{2593}' => Some(|x, y| ((x + 2 * y) & 3) != 2),
        _ => None,
    }
}

/// Build the standard 256-color palette: VGA-ish 16, then the xterm
/// 6×6×6 cube, then the 24-step grayscale ramp. Indexed by `Attr.fg/bg`.
pub fn build_palette() -> [u32; 256] {
    let base16: [u32; 16] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0021AA, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ];
    let cube: [u8; 6] = [0, 95, 135, 175, 215, 255];
    let mut p = [0u32; 256];
    p[..16].copy_from_slice(&base16);
    let mut i = 16;
    for r in 0..6 {
        for g in 0..6 {
            for b in 0..6 {
                p[i] = ((cube[r] as u32) << 16) | ((cube[g] as u32) << 8) | cube[b] as u32;
                i += 1;
            }
        }
    }
    for k in 0..24 {
        let v = 8 + 10 * k as u32;
        p[232 + k] = (v << 16) | (v << 8) | v;
    }
    p
}

/// Paint `cells` (a `cols`×`rows` grid) into `buf` (a `win_w`×`win_h`
/// pixel buffer in 0x00RRGGBB), using `atlas` for glyph coverage. This is
/// the per-cell paint loop from the wrapper, minus the cursor handling
/// (turbokod paints its cursor as a reverse-video cell, so it arrives in
/// the cell data already).
pub fn paint(
    atlas: &mut Atlas,
    buf: &mut [u32],
    win_w: usize,
    win_h: usize,
    cells: &[RenderCell],
    cols: usize,
    rows: usize,
) {
    let cw = atlas.cell_w() as usize;
    let ch = atlas.cell_h() as usize;
    let scale = atlas.scale as i32;

    // Clear any margin strip outside the cell grid (when the window size
    // isn't an exact multiple of the cell size).
    let cells_w = cols * cw;
    let cells_h = rows * ch;
    if cells_w < win_w || cells_h < win_h {
        for px in buf.iter_mut() {
            *px = DEFAULT_BG;
        }
    }

    for line in 0..rows {
        for col in 0..cols {
            let cell = cells.get(line * cols + col).copied().unwrap_or(RenderCell {
                c: ' ',
                fg: DEFAULT_FG,
                bg: DEFAULT_BG,
                underline: UnderlineKind::None,
                underline_color: DEFAULT_FG,
            });
            let x0 = col * cw;
            let y0 = line * ch;

            if let Some(dither) = shade_dither(cell.c) {
                for y in 0..ch {
                    let sy = (y0 + y) as i32 / scale;
                    let row_base = (y0 + y) * win_w + x0;
                    for x in 0..cw {
                        let sx = (x0 + x) as i32 / scale;
                        let px = if dither(sx, sy) { cell.fg } else { cell.bg };
                        let idx = row_base + x;
                        if idx < buf.len() {
                            buf[idx] = px;
                        }
                    }
                }
            } else {
                match atlas.glyph(cell.c) {
                    AtlasGlyph::Coverage(g) => {
                        for y in 0..ch {
                            let row_base = (y0 + y) * win_w + x0;
                            for x in 0..cw {
                                let cov = g[y * cw + x] as u32;
                                let px = blend(cell.fg, cell.bg, cov);
                                let idx = row_base + x;
                                if idx < buf.len() {
                                    buf[idx] = px;
                                }
                            }
                        }
                    }
                    AtlasGlyph::Color(g) => {
                        for y in 0..ch {
                            let row_base = (y0 + y) * win_w + x0;
                            for x in 0..cw {
                                let sp = g[y * cw + x];
                                let a = (sp >> 24) & 0xFF;
                                let idx = row_base + x;
                                if idx >= buf.len() {
                                    continue;
                                }
                                if a == 0 {
                                    buf[idx] = cell.bg;
                                    continue;
                                }
                                let inv = 255 - a;
                                let sr = (sp >> 16) & 0xFF;
                                let sg = (sp >> 8) & 0xFF;
                                let sb = sp & 0xFF;
                                let br = (cell.bg >> 16) & 0xFF;
                                let bg_ = (cell.bg >> 8) & 0xFF;
                                let bb = cell.bg & 0xFF;
                                let r = (sr + (inv * br) / 255).min(255);
                                let gr = (sg + (inv * bg_) / 255).min(255);
                                let b = (sb + (inv * bb) / 255).min(255);
                                buf[idx] = (r << 16) | (gr << 8) | b;
                            }
                        }
                    }
                }
            }

            // Underline overlay, stamped after the glyph.
            if cell.underline != UnderlineKind::None {
                let uc = cell.underline_color;
                let thickness = (scale as usize).max(1);
                let baseline = ch.saturating_sub(thickness + 1);
                match cell.underline {
                    UnderlineKind::Plain => {
                        for ty in 0..thickness {
                            let yy = baseline + ty;
                            if yy >= ch {
                                break;
                            }
                            let row_base = (y0 + yy) * win_w + x0;
                            for x in 0..cw {
                                let idx = row_base + x;
                                if idx < buf.len() {
                                    buf[idx] = uc;
                                }
                            }
                        }
                    }
                    UnderlineKind::Curly => {
                        let top = baseline;
                        let bot = (baseline + thickness).min(ch.saturating_sub(1));
                        for x in 0..cw {
                            let phase = ((x0 + x) / thickness.max(1)) % 4;
                            let yy = if phase < 2 { top } else { bot };
                            if yy >= ch {
                                continue;
                            }
                            let idx = (y0 + yy) * win_w + x0 + x;
                            if idx < buf.len() {
                                buf[idx] = uc;
                            }
                        }
                    }
                    UnderlineKind::None => {}
                }
            }
        }
    }
}
