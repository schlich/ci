//! `ci tower`: a live terminal control tower for the `ci` topic workflow.
//!
//! The board shows every workspace's topic where the lifecycle machine in
//! ../lifecycle places it, with the run moving it; the runs view follows each
//! `ci` run's OSC 7501 phases and log; the trunk view lists what landed and
//! which releases this host verified. Space runs a `ci` step for the selected
//! topic as a job agents can follow too.

mod ansi;
mod app;
mod feed;
mod host;
mod jobs;
mod repo;
mod theme;
mod time;
mod ui;

use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use ratatui::backend::TestBackend;
use ratatui::buffer::Buffer;
use ratatui::crossterm::event::Event;
use ratatui::style::{Color, Modifier};
use ratatui::Terminal;

use app::{App, View};
use feed::Msg;
use theme::Theme;

const USAGE: &str = "\
ci-tower: a live control tower for the ci topic workflow

Usage: ci-tower [DIR] [--theme synthwave|ansi]
       ci-tower [DIR] --json
       ci-tower [DIR] --snapshot WxH [--view board|runs|trunk] [--html]

  DIR         a directory inside the JJ repository (default: here)
  --theme     colors: truecolor neon or the terminal's own palette
  --json      print the collected topics, runs, and locks, then exit
  --snapshot  render one frame at WxH as text (or --html), then exit

Keys are listed in the hint bar at the bottom; ? shows them all.";

/// Copies `text` to the clipboard through the terminal (OSC 52).
pub fn osc52(text: &str) {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes = text.as_bytes();
    let mut encoded = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, b)| n | (*b as u32) << (16 - 8 * i));
        for i in 0..4 {
            if i <= chunk.len() {
                encoded.push(TABLE[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                encoded.push('=');
            }
        }
    }
    let mut stdout = std::io::stdout();
    let _ = write!(stdout, "\x1b]52;c;{encoded}\x07");
    let _ = stdout.flush();
}

struct Options {
    dir: PathBuf,
    theme: Option<String>,
    json: bool,
    snapshot: Option<(u16, u16)>,
    view: View,
    html: bool,
}

fn options() -> Result<Options, String> {
    let mut options = Options {
        dir: std::env::current_dir().map_err(|e| e.to_string())?,
        theme: None,
        json: false,
        snapshot: None,
        view: View::Board,
        html: false,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-h" | "--help" => return Err(String::new()),
            "--version" => {
                println!("ci-tower {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            "--theme" => options.theme = Some(args.next().ok_or("--theme needs a name")?),
            "--json" => options.json = true,
            "--html" => options.html = true,
            "--snapshot" => {
                let size = args.next().ok_or("--snapshot needs WxH")?;
                let (w, h) = size
                    .split_once('x')
                    .ok_or("--snapshot needs WxH, such as 120x36")?;
                options.snapshot = Some((
                    w.parse().map_err(|_| "bad width")?,
                    h.parse().map_err(|_| "bad height")?,
                ));
            }
            "--view" => {
                options.view = match args.next().as_deref() {
                    Some("board") => View::Board,
                    Some("runs") => View::Runs,
                    Some("trunk") => View::Trunk,
                    _ => return Err("--view takes board, runs, or trunk".into()),
                }
            }
            other if !other.starts_with('-') => options.dir = PathBuf::from(other),
            other => return Err(format!("unknown option {other}")),
        }
    }
    Ok(options)
}

fn main() {
    let options = match options() {
        Ok(options) => options,
        Err(error) => {
            if !error.is_empty() {
                eprintln!("ci-tower: {error}\n");
            }
            eprintln!("{USAGE}");
            std::process::exit(if error.is_empty() { 0 } else { 2 });
        }
    };
    let theme = Theme::pick(options.theme.as_deref());
    let ci = std::env::var("CI_TOWER_CI").unwrap_or_else(|_| "ci".into());
    if options.json || options.snapshot.is_some() {
        std::process::exit(once(options, theme, ci));
    }
    if repo::workspace_root(&options.dir).is_none() {
        eprintln!(
            "ci-tower: {} is not inside a JJ workspace",
            options.dir.display()
        );
        std::process::exit(2);
    }
    let (tx, rx) = mpsc::channel();
    let feed = feed::start(options.dir, tx);
    let mut app = App::new(theme, ci, Some(feed));
    let mut terminal = ratatui::init();
    let result = run(&mut terminal, &mut app, rx);
    ratatui::restore();
    if let Err(error) = result {
        eprintln!("ci-tower: {error}");
        std::process::exit(1);
    }
}

fn apply(app: &mut App, msg: Msg) -> bool {
    match msg {
        Msg::Input(Event::Key(key)) => {
            app.handle_key(key);
            true
        }
        Msg::Input(Event::Resize(..)) => true,
        Msg::Input(_) => false,
        Msg::Snapshot(Ok(snapshot)) => {
            app.set_snapshot(*snapshot);
            true
        }
        Msg::Snapshot(Err(error)) => {
            app.snapshot_error = Some(error);
            true
        }
        Msg::Runs(runs) => {
            app.runs = runs;
            app.sync_follow();
            true
        }
        Msg::Locks(locks) => {
            app.locks = locks;
            true
        }
        Msg::Host(host) => {
            app.host = host;
            true
        }
        Msg::Log { run, lines, reset } => {
            app.append_log(run, lines, reset);
            true
        }
    }
}

fn run(
    terminal: &mut ratatui::DefaultTerminal,
    app: &mut App,
    rx: mpsc::Receiver<Msg>,
) -> std::io::Result<()> {
    let mut dirty = true;
    loop {
        if dirty {
            terminal.draw(|frame| ui::draw(frame, app))?;
            dirty = false;
        }
        // Spinners and clocks need frames; an idle board needs one a second.
        let wait = if app.animating() {
            Duration::from_millis(90)
        } else {
            Duration::from_millis(1_000)
        };
        match rx.recv_timeout(wait) {
            Ok(msg) => {
                dirty |= apply(app, msg);
                // Take everything already queued before drawing again.
                while let Ok(msg) = rx.try_recv() {
                    dirty |= apply(app, msg);
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                app.tick();
                dirty = true;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
        }
        if app.quit {
            return Ok(());
        }
    }
}

/// `--json` and `--snapshot`: collect once, synchronously, and print.
fn once(options: Options, theme: Theme, ci: String) -> i32 {
    let snapshot = match repo::snapshot(&options.dir) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            eprintln!("ci-tower: {error}");
            return 1;
        }
    };
    let runs = jobs::Scanner::default().scan();
    let locks = host::LockReader::default().read();
    let host = host::host_info();
    if options.json {
        let value =
            serde_json::json!({ "snapshot": snapshot, "runs": runs, "locks": locks, "host": host });
        println!(
            "{}",
            serde_json::to_string_pretty(&value).unwrap_or_default()
        );
        return 0;
    }
    let mut app = App::new(theme, ci, None);
    app.set_snapshot(snapshot);
    app.runs = runs;
    app.locks = locks;
    app.host = host;
    app.view = options.view;
    if let Some(run) = app.selected_run() {
        let (id, path) = (run.id.clone(), run.log.clone());
        let lines = std::fs::read_to_string(&path)
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect();
        app.append_log(id, lines, true);
    }
    let (w, h) = options.snapshot.unwrap_or((120, 36));
    let mut terminal = match Terminal::new(TestBackend::new(w, h)) {
        Ok(terminal) => terminal,
        Err(error) => {
            eprintln!("ci-tower: {error}");
            return 1;
        }
    };
    if let Err(error) = terminal.draw(|frame| ui::draw(frame, &app)) {
        eprintln!("ci-tower: {error}");
        return 1;
    }
    let buffer = terminal.backend().buffer().clone();
    print!(
        "{}",
        if options.html {
            html(&buffer, &app.theme)
        } else {
            text(&buffer)
        }
    );
    0
}

fn text(buffer: &Buffer) -> String {
    let mut out = String::new();
    for y in 0..buffer.area.height {
        let mut skip = 0;
        for x in 0..buffer.area.width {
            if skip > 0 {
                skip -= 1;
                continue;
            }
            let symbol = buffer[(x, y)].symbol();
            skip = unicode_width::UnicodeWidthStr::width(symbol).saturating_sub(1);
            out.push_str(symbol);
        }
        out.push('\n');
    }
    out
}

fn css(color: Color, fallback: &str) -> String {
    let named = match color {
        Color::Reset => return fallback.to_string(),
        Color::Rgb(r, g, b) => return format!("#{r:02x}{g:02x}{b:02x}"),
        Color::Black => "#1d1f21",
        Color::Red => "#cc6666",
        Color::Green => "#b5bd68",
        Color::Yellow => "#f0c674",
        Color::Blue => "#81a2be",
        Color::Magenta => "#b294bb",
        Color::Cyan => "#8abeb7",
        Color::Gray => "#c5c8c6",
        Color::DarkGray => "#666666",
        Color::LightRed => "#d54e53",
        Color::LightGreen => "#b9ca4a",
        Color::LightYellow => "#e7c547",
        Color::LightBlue => "#7aa6da",
        Color::LightMagenta => "#c397d8",
        Color::LightCyan => "#70c0b1",
        Color::White => "#eaeaea",
        Color::Indexed(n) if n >= 232 => {
            let v = 8 + (n - 232) as u32 * 10;
            return format!("#{v:02x}{v:02x}{v:02x}");
        }
        Color::Indexed(_) => "#888888",
    };
    named.to_string()
}

/// One frame as an HTML page, for reviewing the layout outside a terminal.
fn html(buffer: &Buffer, theme: &Theme) -> String {
    let background = "#1a1625";
    let foreground = css(theme.text, "#e6e6e6");
    let mut out = format!(
        "<!doctype html><meta charset=utf-8><title>ci tower</title><style>body{{background:{background};margin:0;padding:16px}}pre{{font:14px/1.25 'Monaspace Krypton','JetBrains Mono',monospace;color:{foreground};margin:0}}</style><pre>"
    );
    for y in 0..buffer.area.height {
        let mut skip = 0;
        for x in 0..buffer.area.width {
            if skip > 0 {
                skip -= 1;
                continue;
            }
            let cell = &buffer[(x, y)];
            skip = unicode_width::UnicodeWidthStr::width(cell.symbol()).saturating_sub(1);
            let mut style = format!("color:{};", css(cell.fg, &foreground));
            if cell.bg != Color::Reset {
                style.push_str(&format!("background:{};", css(cell.bg, background)));
            }
            if cell.modifier.contains(Modifier::BOLD) {
                style.push_str("font-weight:bold;");
            }
            if cell.modifier.contains(Modifier::DIM) {
                style.push_str("opacity:.55;");
            }
            if cell.modifier.contains(Modifier::ITALIC) {
                style.push_str("font-style:italic;");
            }
            let symbol = cell
                .symbol()
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;");
            out.push_str(&format!("<span style=\"{style}\">{symbol}</span>"));
        }
        out.push('\n');
    }
    out.push_str("</pre>");
    out
}
