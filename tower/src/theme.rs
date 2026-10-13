//! Colors and glyphs. Stage glyphs and colors follow `context-status`, so the
//! prompt segment and the tower read the same.

use jj_ci_lifecycle::stage::Stage;
use ratatui::style::{Color, Modifier, Style};

#[derive(Clone, Debug)]
pub struct Theme {
    pub text: Color,
    pub muted: Color,
    pub faint: Color,
    pub border: Color,
    pub accent: Color,
    pub accent2: Color,
    pub selection: Color,
    pub bar: Color,
    pub ok: Color,
    pub warn: Color,
    pub err: Color,
    pub info: Color,
    pub purple: Color,
    pub blue: Color,
    pub orange: Color,
}

impl Theme {
    /// Synthwave '84-like neon on the terminal's own background.
    pub fn synthwave() -> Self {
        Theme {
            text: Color::Rgb(0xf2, 0xee, 0xf8),
            muted: Color::Rgb(0x9a, 0x9f, 0xcf),
            faint: Color::Rgb(0x5d, 0x5f, 0x8c),
            border: Color::Rgb(0x49, 0x41, 0x6e),
            accent: Color::Rgb(0xff, 0x7e, 0xdb),
            accent2: Color::Rgb(0x36, 0xf9, 0xf6),
            selection: Color::Rgb(0x34, 0x29, 0x4f),
            bar: Color::Rgb(0x24, 0x1b, 0x2f),
            ok: Color::Rgb(0x72, 0xf1, 0xb8),
            warn: Color::Rgb(0xfe, 0xde, 0x5d),
            err: Color::Rgb(0xfe, 0x44, 0x50),
            info: Color::Rgb(0x2e, 0xe2, 0xfa),
            purple: Color::Rgb(0xc7, 0x92, 0xea),
            blue: Color::Rgb(0x6e, 0x9b, 0xff),
            orange: Color::Rgb(0xff, 0x8b, 0x39),
        }
    }

    /// The terminal's own sixteen colors, for terminals without truecolor.
    pub fn ansi() -> Self {
        Theme {
            text: Color::Reset,
            muted: Color::Gray,
            faint: Color::DarkGray,
            border: Color::DarkGray,
            accent: Color::LightMagenta,
            accent2: Color::LightCyan,
            selection: Color::Indexed(236),
            bar: Color::Indexed(234),
            ok: Color::Green,
            warn: Color::Yellow,
            err: Color::Red,
            info: Color::Cyan,
            purple: Color::Magenta,
            blue: Color::Blue,
            orange: Color::LightRed,
        }
    }

    /// `--theme`, then CI_TOWER_THEME, then truecolor support decides.
    pub fn pick(requested: Option<&str>) -> Self {
        let env = std::env::var("CI_TOWER_THEME").ok();
        match requested.or(env.as_deref()) {
            Some("ansi") => Theme::ansi(),
            Some("synthwave") => Theme::synthwave(),
            _ => match std::env::var("COLORTERM").as_deref() {
                Ok("truecolor" | "24bit") => Theme::synthwave(),
                _ => Theme::ansi(),
            },
        }
    }

    pub fn fg(&self, color: Color) -> Style {
        Style::default().fg(color)
    }

    pub fn muted(&self) -> Style {
        self.fg(self.muted)
    }

    pub fn faint(&self) -> Style {
        self.fg(self.faint)
    }

    pub fn bold(&self, color: Color) -> Style {
        self.fg(color).add_modifier(Modifier::BOLD)
    }

    pub fn stage_color(&self, stage: Stage) -> Color {
        match stage {
            Stage::Editing => self.blue,
            Stage::Validated => self.info,
            Stage::Republish => self.warn,
            Stage::Stranded => self.err,
            Stage::Published => self.purple,
            Stage::Passed => self.ok,
            Stage::Failed => self.err,
            Stage::Landed => self.ok,
            Stage::Finished | Stage::Idle => self.faint,
        }
    }
}

pub fn stage_glyph(stage: Stage) -> &'static str {
    match stage {
        Stage::Editing => "✎",
        Stage::Validated => "✓",
        Stage::Republish => "↻",
        Stage::Stranded => "⚠",
        Stage::Published => "↑",
        Stage::Passed => "✔",
        Stage::Failed => "✗",
        Stage::Landed | Stage::Finished => "⚑",
        Stage::Idle => "·",
    }
}

pub fn stage_label(stage: Stage) -> &'static str {
    match stage {
        Stage::Editing => "editing",
        Stage::Validated => "validated",
        Stage::Republish => "edited since dispatch",
        Stage::Stranded => "off topic",
        Stage::Published => "dispatched",
        Stage::Passed => "cleared",
        Stage::Failed => "pipeline failed",
        Stage::Landed => "landed",
        Stage::Finished => "parked",
        Stage::Idle => "idle",
    }
}

/// Braille spinner frames, one per animation tick.
pub const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
