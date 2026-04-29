use fontdue::{Font, FontSettings};

const PX437: &[u8] = include_bytes!("../assets/Px437_IBM_VGA_8x16.ttf");

fn dump(font: &Font, ch: char, px: f32) {
    let (m, bm) = font.rasterize(ch, px);
    println!(
        "U+{:04X} {:>2} px:  bitmap {}×{}  xmin={:>3}  ymin={:>3}  advance={:.2}  ({} bytes)",
        ch as u32, px as u32, m.width, m.height, m.xmin, m.ymin, m.advance_width, bm.len()
    );
    if !bm.is_empty() {
        for y in 0..m.height {
            print!("    ");
            for x in 0..m.width {
                let v = bm[y * m.width + x];
                print!("{}", if v == 0 { "." } else if v < 128 { "+" } else { "#" });
            }
            println!();
        }
    }
}

fn main() {
    let font = Font::from_bytes(PX437, FontSettings::default()).unwrap();
    let lm = font.horizontal_line_metrics(16.0).unwrap();
    println!("font.horizontal_line_metrics(16.0):");
    println!("  ascent  = {}", lm.ascent);
    println!("  descent = {}", lm.descent);
    println!("  line_gap= {}", lm.line_gap);
    println!("  new_line_size = {}", lm.new_line_size);
    println!("  units_per_em? (units_per_em ratio at 16px)\n");

    let chars: &[(char, &str)] = &[
        ('\u{2591}', "LIGHT SHADE"),
        ('\u{2592}', "MEDIUM SHADE"),
        ('\u{2593}', "DARK SHADE"),
        ('\u{2588}', "FULL BLOCK"),
    ];
    for &(c, label) in chars {
        println!("--- {} ({}) ---", label, c);
        dump(&font, c, 16.0);
        println!();
    }
}
