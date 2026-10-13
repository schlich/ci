//! Log lines with ANSI escapes, as styled spans. Only SGR colors and
//! attributes are kept; every other escape is dropped, and a carriage return
//! keeps what was written after it, as a terminal would show a progress line.

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

fn basic(code: u16, bright: bool) -> Color {
    match (code, bright) {
        (0, false) => Color::Black,
        (1, false) => Color::Red,
        (2, false) => Color::Green,
        (3, false) => Color::Yellow,
        (4, false) => Color::Blue,
        (5, false) => Color::Magenta,
        (6, false) => Color::Cyan,
        (7, false) => Color::Gray,
        (0, true) => Color::DarkGray,
        (1, true) => Color::LightRed,
        (2, true) => Color::LightGreen,
        (3, true) => Color::LightYellow,
        (4, true) => Color::LightBlue,
        (5, true) => Color::LightMagenta,
        (6, true) => Color::LightCyan,
        _ => Color::White,
    }
}

/// Applies one SGR parameter list to `style`.
fn apply_sgr(params: &str, base: Style, mut style: Style) -> Style {
    let codes: Vec<u16> = if params.is_empty() {
        vec![0]
    } else {
        params
            .split([';', ':'])
            .map(|p| p.parse().unwrap_or(0))
            .collect()
    };
    let mut index = 0;
    while index < codes.len() {
        let code = codes[index];
        match code {
            0 => style = base,
            1 => style = style.add_modifier(Modifier::BOLD),
            2 => style = style.add_modifier(Modifier::DIM),
            3 => style = style.add_modifier(Modifier::ITALIC),
            4 => style = style.add_modifier(Modifier::UNDERLINED),
            7 => style = style.add_modifier(Modifier::REVERSED),
            22 => style = style.remove_modifier(Modifier::BOLD | Modifier::DIM),
            23 => style = style.remove_modifier(Modifier::ITALIC),
            24 => style = style.remove_modifier(Modifier::UNDERLINED),
            27 => style = style.remove_modifier(Modifier::REVERSED),
            30..=37 => style = style.fg(basic(code - 30, false)),
            39 => style.fg = base.fg,
            40..=47 => style = style.bg(basic(code - 40, false)),
            49 => style.bg = base.bg,
            90..=97 => style = style.fg(basic(code - 90, true)),
            100..=107 => style = style.bg(basic(code - 100, true)),
            38 | 48 => {
                let color = match codes.get(index + 1) {
                    Some(5) => {
                        let color = codes.get(index + 2).map(|&n| Color::Indexed(n as u8));
                        index += 2;
                        color
                    }
                    Some(2) => {
                        let rgb = (
                            codes.get(index + 2),
                            codes.get(index + 3),
                            codes.get(index + 4),
                        );
                        index += 4;
                        match rgb {
                            (Some(&r), Some(&g), Some(&b)) => {
                                Some(Color::Rgb(r as u8, g as u8, b as u8))
                            }
                            _ => None,
                        }
                    }
                    _ => None,
                };
                if let Some(color) = color {
                    style = if code == 38 {
                        style.fg(color)
                    } else {
                        style.bg(color)
                    };
                }
            }
            _ => {}
        }
        index += 1;
    }
    style
}

/// The text a terminal would leave on screen for one line: after the last
/// carriage return, with tabs expanded.
fn visible(raw: &str) -> &str {
    let raw = raw.strip_suffix('\r').unwrap_or(raw);
    match raw.rfind('\r') {
        Some(at) => &raw[at + 1..],
        None => raw,
    }
}

/// Splits one raw log line into styled spans over `base`.
pub fn line(raw: &str, base: Style) -> Line<'static> {
    let raw = visible(raw);
    let mut spans = Vec::new();
    let mut style = base;
    let mut text = String::new();
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\x1b' => match chars.peek() {
                Some('[') => {
                    chars.next();
                    let mut params = String::new();
                    let mut last = None;
                    for c in chars.by_ref() {
                        if ('\x40'..='\x7e').contains(&c) {
                            last = Some(c);
                            break;
                        }
                        params.push(c);
                    }
                    if last == Some('m') {
                        if !text.is_empty() {
                            spans.push(Span::styled(std::mem::take(&mut text), style));
                        }
                        style = apply_sgr(&params, base, style);
                    }
                }
                Some(']') => {
                    // OSC: up to BEL or ST.
                    chars.next();
                    while let Some(c) = chars.next() {
                        if c == '\x07' {
                            break;
                        }
                        if c == '\x1b' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                _ => {
                    chars.next();
                }
            },
            '\t' => {
                let width = unicode_width::UnicodeWidthStr::width(text.as_str());
                text.push_str(&" ".repeat(8 - width % 8));
            }
            c if c.is_control() => {}
            c => text.push(c),
        }
    }
    if !text.is_empty() {
        spans.push(Span::styled(text, style));
    }
    Line::from(spans)
}

/// The plain text of a raw log line.
#[cfg(test)]
fn strip(raw: &str) -> String {
    line(raw, Style::default())
        .spans
        .iter()
        .map(|span| span.content.as_ref())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_colors_and_drops_other_escapes() {
        let parsed = line(
            "\x1b[1;31merror\x1b[0m: \x1b]8;;http://x\x07link\x1b]8;;\x07",
            Style::default(),
        );
        assert_eq!(parsed.spans.len(), 2);
        assert_eq!(parsed.spans[0].content, "error");
        assert_eq!(parsed.spans[0].style.fg, Some(Color::Red));
        assert_eq!(parsed.spans[1].content, ": link");
    }

    #[test]
    fn a_carriage_return_overwrites() {
        assert_eq!(strip("building 1/3\rbuilding 3/3"), "building 3/3");
        assert_eq!(strip("done\r"), "done");
    }

    #[test]
    fn truecolor_and_indexed() {
        let parsed = line("\x1b[38;2;1;2;3mx\x1b[48;5;200my", Style::default());
        assert_eq!(parsed.spans[0].style.fg, Some(Color::Rgb(1, 2, 3)));
        assert_eq!(parsed.spans[1].style.bg, Some(Color::Indexed(200)));
    }
}
