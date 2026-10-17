//! Drawing. Every frame is built from `App` alone; nothing here blocks.

use jj_ci_lifecycle::stage::Stage;
use ratatui::layout::{Alignment, Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};
use ratatui::widgets::{Block, BorderType, Clear, Paragraph, Wrap};
use ratatui::Frame;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::app::{Action, App, Group, Level, Mode, View};
use crate::host::tilde;
use crate::jobs::{Phase, PhaseState, Run, RunState};
use crate::repo::{Lint, Topic};
use crate::theme::{stage_glyph, stage_label, Theme, SPINNER};
use crate::{ansi, time};

// ── text helpers ────────────────────────────────────────────────────────────

fn width(text: &str) -> usize {
    UnicodeWidthStr::width(text)
}

/// `text` cut to `max` columns, ending in `…` when cut.
pub fn truncate(text: &str, max: usize) -> String {
    if width(text) <= max {
        return text.to_string();
    }
    if max == 0 {
        return String::new();
    }
    let mut out = String::new();
    let mut used = 0;
    for c in text.chars() {
        let w = c.width().unwrap_or(0);
        if used + w + 1 > max {
            break;
        }
        out.push(c);
        used += w;
    }
    out.push('…');
    out
}

fn spans_width(spans: &[Span]) -> usize {
    spans.iter().map(|s| width(&s.content)).sum()
}

/// Cuts a span list to `max` columns.
fn fit(spans: Vec<Span<'static>>, max: usize) -> Vec<Span<'static>> {
    let mut out = Vec::new();
    let mut used = 0;
    for span in spans {
        let w = width(&span.content);
        if used + w <= max {
            used += w;
            out.push(span);
        } else {
            let room = max.saturating_sub(used);
            if room > 0 {
                out.push(Span::styled(truncate(&span.content, room), span.style));
            }
            break;
        }
    }
    out
}

/// `left` and `right` on one line of `w` columns, the right side kept whole.
fn split_line(left: Vec<Span<'static>>, right: Vec<Span<'static>>, w: usize) -> Line<'static> {
    let right_w = spans_width(&right);
    let room = w.saturating_sub(right_w + 1);
    let mut spans = fit(left, room);
    let gap = w.saturating_sub(spans_width(&spans) + right_w);
    spans.push(Span::raw(" ".repeat(gap)));
    spans.extend(right);
    Line::from(spans)
}

/// Greedy word wrap to `w` columns.
fn wrap(text: &str, w: usize) -> Vec<String> {
    let mut lines = vec![];
    let mut line = String::new();
    for word in text.split_whitespace() {
        if !line.is_empty() && width(&line) + 1 + width(word) > w {
            lines.push(std::mem::take(&mut line));
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(&truncate(word, w));
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

fn sep(theme: &Theme) -> Span<'static> {
    Span::styled(" · ", theme.faint())
}

fn spinner(app: &App) -> &'static str {
    SPINNER[app.frame % SPINNER.len()]
}

fn panel<'a>(theme: &Theme, title: impl Into<Line<'a>>, focused: bool) -> Block<'a> {
    Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(theme.fg(if focused { theme.accent } else { theme.border }))
        .title(title)
}

fn title_spans(theme: &Theme, text: &str, focused: bool) -> Line<'static> {
    Line::from(vec![
        Span::raw(" "),
        Span::styled(
            text.to_string(),
            if focused {
                theme.bold(theme.accent)
            } else {
                theme.bold(theme.muted)
            },
        ),
        Span::raw(" "),
    ])
}

fn impact_style(theme: &Theme, impact: &str) -> Style {
    match impact {
        "refactor" => theme.muted(),
        "behavior" => theme.fg(theme.orange),
        "breaking" | "mixed" => theme.bold(theme.err),
        _ => theme.fg(theme.warn),
    }
}

fn run_glyph(app: &App, run: &Run) -> Span<'static> {
    let theme = &app.theme;
    match run.state {
        RunState::Running => Span::styled(spinner(app), theme.bold(theme.warn)),
        RunState::Succeeded => Span::styled("✔", theme.fg(theme.ok)),
        RunState::Failed => Span::styled("✗", theme.bold(theme.err)),
        RunState::Lost => Span::styled("?", theme.fg(theme.warn)),
    }
}

fn phase_glyph(app: &App, run: &Run, phase: &Phase) -> Span<'static> {
    let theme = &app.theme;
    let unfinished = matches!(
        phase.state,
        PhaseState::Working | PhaseState::Blocked | PhaseState::Permission
    );
    // A phase still open when its run ended is where the run stopped.
    if unfinished && run.state != RunState::Running {
        return match run.state {
            RunState::Lost => Span::styled("?", theme.fg(theme.warn)),
            RunState::Failed => Span::styled("✗", theme.bold(theme.err)),
            _ => Span::styled("·", theme.faint()),
        };
    }
    match phase.state {
        PhaseState::Working => Span::styled(spinner(app), theme.bold(theme.warn)),
        PhaseState::Done => Span::styled("✔", theme.fg(theme.ok)),
        PhaseState::Error => Span::styled("✗", theme.bold(theme.err)),
        PhaseState::Blocked => Span::styled("◌", theme.fg(theme.purple)),
        PhaseState::Permission => Span::styled("✋", theme.bold(theme.accent)),
    }
}

fn run_elapsed(run: &Run, now: i64) -> i64 {
    run.ended_ms.unwrap_or(now) - run.started_ms
}

/// `landing`, `dispatching`, ... for a running run's status label.
fn gerund(verb: &str) -> String {
    match verb {
        "land" => "landing".into(),
        "dispatch" => "dispatching".into(),
        "preflight" => "preflighting".into(),
        "rebase" => "rebasing".into(),
        "park" => "parking".into(),
        "cancel" => "cancelling".into(),
        "sequence" => "sequencing".into(),
        other => format!("ci {other}"),
    }
}

/// Short chips for a run's phases: `✔ rebase  ✔ preflight  ⠹ push`.
fn phase_chips(app: &App, run: &Run, max: usize) -> Vec<Span<'static>> {
    let theme = &app.theme;
    let mut spans = vec![];
    for (index, phase) in run.phases.iter().enumerate() {
        if index > 0 {
            spans.push(Span::styled(" › ", theme.faint()));
        }
        spans.push(phase_glyph(app, run, phase));
        let style = match phase.state {
            PhaseState::Working | PhaseState::Blocked | PhaseState::Permission => {
                theme.fg(theme.text)
            }
            PhaseState::Error => theme.fg(theme.err),
            PhaseState::Done => theme.muted(),
        };
        spans.push(Span::styled(format!(" {}", phase.id), style));
    }
    // Keep the newest phases visible when they do not all fit.
    while spans_width(&spans) > max && spans.len() > 3 {
        spans.drain(..3.min(spans.len()));
        if spans.first().is_some_and(|s| s.content.as_ref() == " › ") {
            spans.remove(0);
        }
        spans.insert(0, Span::styled("… ", theme.faint()));
    }
    fit(spans, max)
}

// ── frame ───────────────────────────────────────────────────────────────────

pub fn draw(frame: &mut Frame, app: &App) {
    let area = frame.area();
    frame.render_widget(
        Block::default().style(Style::default().fg(app.theme.text)),
        area,
    );
    let [header, body, hints] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Fill(1),
        Constraint::Length(1),
    ])
    .areas(area);
    draw_header(frame, header, app);
    match app.view {
        View::Board => draw_board(frame, body, app),
        View::Runs => draw_runs(frame, body, app),
        View::Trunk => draw_trunk(frame, body, app),
    }
    draw_hints(frame, hints, app);
    match &app.mode {
        Mode::Action => draw_actions(frame, body, app),
        Mode::Confirm(_) => draw_confirm(frame, area, app),
        Mode::Help => draw_help(frame, area, app),
        _ => {}
    }
    draw_toast(frame, body, app);
}

fn draw_header(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let bar = Style::default().bg(theme.bar);
    frame.render_widget(Block::default().style(bar), area);
    let mut left = vec![
        Span::styled(" ✈ ci tower ", theme.bold(theme.accent)),
        Span::raw(" "),
    ];
    for (index, view) in View::ALL.iter().enumerate() {
        let label = format!(" {} {} ", index + 1, view.title());
        if *view == app.view {
            left.push(Span::styled(
                label,
                Style::default()
                    .fg(theme.bar)
                    .bg(theme.accent2)
                    .add_modifier(Modifier::BOLD),
            ));
        } else {
            left.push(Span::styled(label, theme.muted()));
        }
    }
    let now = time::now_ms();
    let mut right: Vec<Span> = vec![];
    if let Some(snapshot) = &app.snapshot {
        if let Some(tip) = snapshot.trunk.first() {
            right.push(Span::styled("main ", theme.faint()));
            right.push(Span::styled(
                tip.commit_id[..7.min(tip.commit_id.len())].to_string(),
                theme.fg(theme.accent2),
            ));
            right.push(Span::styled(
                format!(" {}", time::ago(tip.time_ms, now)),
                theme.faint(),
            ));
        }
        if let Some((release, _)) = snapshot
            .trunk
            .iter()
            .find_map(|c| c.tags.iter().find(|t| is_release(t)).map(|t| (t, c)))
        {
            right.push(sep(theme));
            right.push(Span::styled(format!("⚑ {release}"), theme.fg(theme.accent)));
            if app.host.verified.contains_key(release) {
                right.push(Span::styled(" ✔", theme.fg(theme.ok)));
            }
        }
    }
    right.push(sep(theme));
    match &app.locks.checks {
        Some(holder) => {
            right.push(Span::styled(
                format!("{} checks ", spinner(app)),
                theme.bold(theme.warn),
            ));
            right.push(Span::styled(
                holder.change().to_string(),
                theme.fg(theme.warn),
            ));
            if let Some(since) = holder.since_ms {
                right.push(Span::styled(
                    format!(" {}", time::duration(now - since)),
                    theme.faint(),
                ));
            }
        }
        None => right.push(Span::styled("checks idle", theme.faint())),
    }
    right.push(sep(theme));
    right.push(Span::styled(
        format!("{} ", time::clock(now)),
        theme.muted(),
    ));
    let w = area.width as usize;
    // Drop the trunk details before the tabs when the line is narrow.
    while spans_width(&left) + spans_width(&right) + 1 > w && right.len() > 2 {
        right.remove(0);
    }
    frame.render_widget(Paragraph::new(split_line(left, right, w)).style(bar), area);
}

pub fn is_release(tag: &str) -> bool {
    let parts: Vec<&str> = tag.split('.').collect();
    parts.len() == 4
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

// ── board ───────────────────────────────────────────────────────────────────

fn draw_board(frame: &mut Frame, area: Rect, app: &App) {
    let show_strip = area.height >= 26 && !app.runs.is_empty();
    let strip_rows = if show_strip {
        app.runs.len().min(3) as u16 + 2
    } else {
        0
    };
    let [main, strip] =
        Layout::vertical([Constraint::Fill(1), Constraint::Length(strip_rows)]).areas(area);
    let (list, detail) = if main.width >= 110 {
        let [list, detail] =
            Layout::horizontal([Constraint::Percentage(56), Constraint::Percentage(44)])
                .areas(main);
        (list, detail)
    } else {
        let [list, detail] =
            Layout::vertical([Constraint::Percentage(58), Constraint::Percentage(42)]).areas(main);
        (list, detail)
    };
    draw_topic_list(frame, list, app);
    draw_topic_detail(frame, detail, app);
    if show_strip {
        draw_run_strip(frame, strip, app);
    }
}

fn group_color(theme: &Theme, group: Group) -> Color {
    match group {
        Group::Active => theme.warn,
        Group::Attention => theme.err,
        Group::Dispatched => theme.purple,
        Group::Working => theme.blue,
        Group::Landed => theme.ok,
        Group::Idle => theme.faint,
    }
}

/// The right-hand status of a topic row: what runs now, else its stage.
fn topic_status(app: &App, topic: &Topic) -> Vec<Span<'static>> {
    let theme = &app.theme;
    let now = time::now_ms();
    if let Some(run) = app.active_run(topic) {
        let mut spans = vec![Span::styled(gerund(&run.verb()), theme.bold(theme.warn))];
        if let Some(phase) = run.current_phase() {
            let style = match phase.state {
                PhaseState::Permission => theme.bold(theme.accent),
                PhaseState::Blocked => theme.fg(theme.purple),
                _ => theme.fg(theme.warn),
            };
            spans.push(Span::styled(format!(" · {}", phase.id), style));
        }
        spans.push(Span::styled(
            format!(" {}", time::duration(run_elapsed(run, now))),
            theme.faint(),
        ));
        return spans;
    }
    if let Some(holder) = app.topic_lock(topic) {
        return vec![Span::styled(
            format!("locked by pid {}", holder.pid),
            theme.fg(theme.warn),
        )];
    }
    if let Some(run) = app
        .latest_run(topic)
        .filter(|r| matches!(r.state, RunState::Failed | RunState::Lost))
    {
        if run.ended_ms.unwrap_or(run.started_ms) > topic.head.time_ms {
            let what = if run.state == RunState::Lost {
                "lost"
            } else {
                "failed"
            };
            return vec![Span::styled(
                format!("ci {} {what}", run.verb()),
                theme.bold(theme.err),
            )];
        }
    }
    if !topic.conflicts.is_empty() {
        return vec![Span::styled("conflicted", theme.bold(theme.err))];
    }
    vec![Span::styled(
        stage_label(topic.stage).to_string(),
        theme.fg(theme.stage_color(topic.stage)),
    )]
}

fn topic_meta(app: &App, topic: &Topic) -> Vec<Span<'static>> {
    let theme = &app.theme;
    let mut spans = vec![];
    match &topic.workspace {
        Some(name) if topic.current => {
            spans.push(Span::styled(name.clone(), theme.bold(theme.accent2)));
            spans.push(Span::styled(" ◂ here", theme.fg(theme.accent2)));
        }
        Some(name) => spans.push(Span::styled(name.clone(), theme.muted())),
        None => spans.push(Span::styled("⇡ remote branch", theme.fg(theme.purple))),
    }
    spans.push(sep(theme));
    spans.push(Span::styled(
        topic.head.short.clone(),
        theme.fg(theme.purple),
    ));
    if let Some(impact) = topic.impact() {
        spans.push(sep(theme));
        spans.push(Span::styled(impact.clone(), impact_style(theme, &impact)));
    }
    if topic.stack.len() > 1 {
        spans.push(sep(theme));
        spans.push(Span::styled(
            format!("{} changes", topic.stack.len()),
            theme.muted(),
        ));
    }
    match topic.behind {
        Some(0) => {}
        Some(n) if !topic.idle => {
            spans.push(sep(theme));
            spans.push(Span::styled(
                format!("↓{n}"),
                if n > 20 {
                    theme.fg(theme.warn)
                } else {
                    theme.faint()
                },
            ));
        }
        None if !topic.idle => {
            spans.push(sep(theme));
            spans.push(Span::styled(
                format!("↓{}+", crate::repo::TRUNK_DEPTH),
                theme.fg(theme.warn),
            ));
        }
        _ => {}
    }
    if !topic.conflicts.is_empty() {
        spans.push(sep(theme));
        spans.push(Span::styled(
            format!("⚠ {} conflicted", topic.conflicts.len()),
            theme.bold(theme.err),
        ));
    }
    if matches!(topic.stage, Stage::Editing | Stage::Validated) {
        spans.push(sep(theme));
        spans.push(match topic.lint {
            Lint::Passed { .. } => Span::styled("✔ preflight", theme.fg(theme.ok)),
            Lint::Stale => Span::styled("preflight stale", theme.faint()),
            Lint::Never => Span::styled("no preflight", theme.faint()),
        });
    }
    if let Some(ci) = &topic.ci {
        if let Some(pull) = &ci.pull {
            spans.push(sep(theme));
            spans.push(Span::styled(
                format!("PR {}", truncate(pull, 24)),
                theme.fg(theme.info),
            ));
        }
    }
    if app.holds_checks(topic) {
        spans.push(sep(theme));
        spans.push(Span::styled("■ holds checks", theme.fg(theme.warn)));
    }
    if topic.owner == "active" {
        spans.push(sep(theme));
        spans.push(Span::styled("◆ codex", theme.faint()));
    }
    spans
}

fn draw_topic_list(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let board = app.board();
    let selected = app.board_selection(&board);
    let mut counts = vec![];
    for group in [Group::Active, Group::Attention, Group::Dispatched] {
        let n = board.iter().filter(|(g, _)| *g == group).count();
        if n > 0 {
            counts.push(Span::styled(
                format!("{n} {}", group.title().to_lowercase()),
                theme.fg(group_color(theme, group)),
            ));
            counts.push(Span::styled(" · ", theme.faint()));
        }
    }
    let hidden = app.hidden_idle();
    if hidden > 0 {
        counts.push(Span::styled(
            format!("{hidden} idle hidden "),
            theme.faint(),
        ));
    } else if !counts.is_empty() {
        counts.pop();
        counts.push(Span::raw(" "));
    }
    // Leave the panel's own title room: drop the least urgent counts first.
    let room = (area.width as usize).saturating_sub(12);
    while spans_width(&counts) > room && !counts.is_empty() {
        counts.pop();
        if counts
            .last()
            .is_some_and(|s| s.content.trim().is_empty() || s.content.as_ref() == " · ")
        {
            counts.pop();
        }
    }
    if counts.last().is_some_and(|s| !s.content.ends_with(' ')) {
        counts.push(Span::raw(" "));
    }
    let mut block = panel(theme, title_spans(theme, "Topics", true), true)
        .title_top(Line::from(counts).right_aligned());
    if !app.filter.is_empty() || matches!(app.mode, Mode::Filter) {
        let cursor = if matches!(app.mode, Mode::Filter) {
            "▏"
        } else {
            ""
        };
        block = block.title_bottom(Line::from(vec![
            Span::styled(" / ", theme.bold(theme.warn)),
            Span::styled(format!("{}{cursor} ", app.filter), theme.fg(theme.text)),
        ]));
    }
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let w = inner.width as usize;

    if app.snapshot.is_none() {
        let text = match &app.snapshot_error {
            Some(error) => Line::from(Span::styled(format!("✗ {error}"), theme.fg(theme.err))),
            None => Line::from(vec![
                Span::styled(spinner(app), theme.fg(theme.accent)),
                Span::styled(" Reading the graph…", theme.muted()),
            ]),
        };
        frame.render_widget(
            Paragraph::new(vec![Line::raw(""), text]).alignment(Alignment::Center),
            inner,
        );
        return;
    }
    if board.is_empty() {
        let message = if app.filter.is_empty() {
            "Clear skies. Start a topic with `ci new` or `ci start NAME`."
        } else {
            "Nothing on the board matches the filter."
        };
        let mut lines = vec![
            Line::raw(""),
            Line::from(Span::styled(message, theme.muted())),
        ];
        if hidden > 0 {
            lines.push(Line::from(Span::styled(
                format!("{hidden} idle workspaces hidden · i shows them"),
                theme.faint(),
            )));
        }
        frame.render_widget(Paragraph::new(lines).alignment(Alignment::Center), inner);
        return;
    }

    // Lay the rows out as lines, remembering where the selection sits.
    let mut lines: Vec<Line> = vec![];
    let mut selected_range = (0, 0);
    let mut last_group = None;
    for (index, (group, topic)) in board.iter().enumerate() {
        if last_group != Some(*group) {
            if last_group.is_some() {
                lines.push(Line::raw(""));
            }
            let title = format!(" {} ", group.title());
            let count = board.iter().filter(|(g, _)| g == group).count();
            let rule = w.saturating_sub(width(&title) + 6);
            lines.push(Line::from(vec![
                Span::styled(title, theme.bold(group_color(theme, *group))),
                Span::styled("─".repeat(rule), theme.fg(theme.border)),
                Span::styled(format!(" {count:>2} "), theme.faint()),
            ]));
            last_group = Some(*group);
        }
        let is_selected = Some(index) == selected;
        let start = lines.len();
        let glyph = if app.active_run(topic).is_some() {
            Span::styled(spinner(app), theme.bold(theme.warn))
        } else {
            Span::styled(
                stage_glyph(topic.stage),
                theme.bold(theme.stage_color(topic.stage)),
            )
        };
        let bar = if is_selected {
            Span::styled("▌", theme.fg(theme.accent))
        } else {
            Span::raw(" ")
        };
        let title = if topic.head.title.is_empty() {
            Span::styled(
                "(no description)",
                theme.faint().add_modifier(Modifier::ITALIC),
            )
        } else if is_selected {
            Span::styled(topic.head.title.clone(), theme.bold(theme.text))
        } else {
            Span::styled(topic.head.title.clone(), theme.fg(theme.text))
        };
        let mut status = topic_status(app, topic);
        status.push(Span::raw(" "));
        lines.push(split_line(
            vec![bar.clone(), Span::raw(" "), glyph, Span::raw(" "), title],
            status,
            w,
        ));
        let mut meta = vec![bar, Span::raw("   ")];
        meta.extend(topic_meta(app, topic));
        lines.push(Line::from(fit(meta, w)));
        if is_selected {
            for line in &mut lines[start..] {
                line.style = Style::default().bg(theme.selection);
            }
            selected_range = (start, lines.len());
        }
    }
    let height = inner.height as usize;
    let mut offset = app.board_offset.get();
    if selected_range.0 < offset {
        // Show the group heading above the first row too.
        offset = selected_range.0.saturating_sub(if selected_range.0 <= 1 {
            selected_range.0
        } else {
            1
        });
    }
    if selected_range.1 > offset + height {
        offset = selected_range.1 - height;
    }
    offset = offset.min(lines.len().saturating_sub(height));
    app.board_offset.set(offset);
    let visible: Vec<Line> = lines.into_iter().skip(offset).take(height).collect();
    frame.render_widget(Paragraph::new(visible), inner);
}

const STATIONS: [(&str, &str); 6] = [
    ("new", "new"),
    ("preflight", "pre"),
    ("dispatch", "disp"),
    ("clearance", "clr"),
    ("land", "land"),
    ("park", "park"),
];

#[derive(Clone, Copy, PartialEq)]
enum Station {
    Done,
    Current,
    Running,
    Pending,
    Failed,
    Stale,
}

fn phase_station(id: &str) -> usize {
    // Local clearance reports each check it builds as `clearance/<check>`.
    match id.split('/').next().unwrap_or(id) {
        "rebase" | "preflight" => 1,
        "push" | "remote" => 2,
        "closures" | "clearance" | "local-checks" => 3,
        "park" => 5,
        _ => 4,
    }
}

/// Each station's state on the topic's trip to main.
fn stations(app: &App, topic: &Topic) -> [Station; 6] {
    let mut out = [Station::Pending; 6];
    let (reached, special): (isize, Option<(usize, Station)>) = match topic.stage {
        Stage::Idle => (-1, None),
        Stage::Stranded => (-1, Some((0, Station::Failed))),
        Stage::Editing => (0, None),
        Stage::Validated => (1, None),
        Stage::Republish => (1, Some((2, Station::Stale))),
        Stage::Published => (2, None),
        Stage::Failed => (2, Some((3, Station::Failed))),
        Stage::Passed => (3, None),
        Stage::Landed => (4, None),
        Stage::Finished => (5, None),
    };
    for (index, station) in out.iter_mut().enumerate() {
        if index as isize <= reached {
            *station = Station::Done;
        }
    }
    if let Some(next) = out.get_mut((reached + 1) as usize) {
        *next = Station::Current;
    }
    if let Some((index, state)) = special {
        out[index] = state;
    }
    let run = app.active_run(topic).or_else(|| {
        app.latest_run(topic)
            .filter(|r| r.state == RunState::Failed && r.ended_ms.unwrap_or(0) > topic.head.time_ms)
    });
    if let Some(run) = run {
        let phase = if run.state == RunState::Running {
            run.current_phase()
        } else {
            run.failed_phase().or(run.phases.last())
        };
        if let Some(phase) = phase {
            let at = phase_station(&phase.id);
            for (index, station) in out.iter_mut().enumerate() {
                *station = match index.cmp(&at) {
                    std::cmp::Ordering::Less => Station::Done,
                    std::cmp::Ordering::Equal if run.state == RunState::Running => Station::Running,
                    std::cmp::Ordering::Equal => Station::Failed,
                    std::cmp::Ordering::Greater => Station::Pending,
                };
            }
        }
    }
    out
}

fn flight_path(app: &App, topic: &Topic, w: usize) -> [Line<'static>; 2] {
    let theme = &app.theme;
    let states = stations(app, topic);
    let w = w.clamp(12, 72);
    let short = w < 52;
    let last = STATIONS.len() - 1;
    let position = |index: usize| (index * (w - 1) + last / 2) / last;
    let mut track = vec![];
    for (index, state) in states.iter().enumerate() {
        let (glyph, style) = match state {
            Station::Done => ("●", theme.fg(theme.ok)),
            Station::Current => ("◉", theme.bold(theme.accent)),
            Station::Running => (spinner(app), theme.bold(theme.warn)),
            Station::Pending => ("○", theme.faint()),
            Station::Failed => ("✗", theme.bold(theme.err)),
            Station::Stale => ("↻", theme.bold(theme.warn)),
        };
        track.push(Span::styled(glyph, style));
        if index < last {
            let gap = position(index + 1) - position(index) - 1;
            let reached = states[index + 1] == Station::Done
                || (state == &Station::Done && states[index + 1] != Station::Pending);
            let (rule, style) = if reached {
                ("━", theme.fg(theme.ok))
            } else {
                ("┄", theme.faint())
            };
            track.push(Span::styled(rule.repeat(gap), style));
        }
    }
    let mut labels = vec![];
    let mut used = 0;
    for (index, (long, abbreviated)) in STATIONS.iter().enumerate() {
        let label = if short { *abbreviated } else { *long };
        let centered = position(index).saturating_sub(label.len() / 2);
        let start = centered.max(used).min(w.saturating_sub(label.len()));
        if start > used {
            labels.push(Span::raw(" ".repeat(start - used)));
        }
        let style = match states[index] {
            Station::Current | Station::Running => theme.bold(theme.text),
            Station::Done => theme.muted(),
            Station::Failed => theme.fg(theme.err),
            Station::Stale => theme.fg(theme.warn),
            Station::Pending => theme.faint(),
        };
        labels.push(Span::styled(label.to_string(), style));
        used = start + label.len() + 1;
        labels.push(Span::raw(" "));
    }
    [Line::from(labels), Line::from(track)]
}

fn field(theme: &Theme, label: &str, value: Vec<Span<'static>>) -> Line<'static> {
    let mut spans = vec![Span::styled(
        format!(" {label:<7} "),
        theme.faint().add_modifier(Modifier::BOLD),
    )];
    spans.extend(value);
    Line::from(spans)
}

fn draw_topic_detail(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let Some(topic) = app.selected_topic() else {
        frame.render_widget(
            panel(theme, title_spans(theme, "Topic", false), false),
            area,
        );
        return;
    };
    let now = time::now_ms();
    let stage_color = theme.stage_color(topic.stage);
    let header = format!(
        "{} · {}",
        topic.head.short,
        topic.workspace.as_deref().unwrap_or("remote")
    );
    let pill = Line::from(vec![
        Span::styled(" ", Style::default()),
        Span::styled(
            format!(
                " {} {} ",
                stage_glyph(topic.stage),
                stage_label(topic.stage)
            ),
            Style::default()
                .fg(theme.bar)
                .bg(stage_color)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
    ])
    .right_aligned();
    let block = panel(theme, title_spans(theme, &header, false), false).title_top(pill);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let w = inner.width as usize;
    let text_w = w.saturating_sub(10).max(10);

    let mut lines: Vec<Line> = vec![];
    let title = if topic.head.title.is_empty() {
        "(no description)".to_string()
    } else {
        topic.head.title.clone()
    };
    for line in wrap(&title, w.saturating_sub(2)).into_iter().take(3) {
        lines.push(Line::from(Span::styled(
            format!(" {line}"),
            theme.bold(theme.text),
        )));
    }
    lines.push(Line::raw(""));
    for line in flight_path(app, topic, w.saturating_sub(4)) {
        let mut spans = vec![Span::raw("  ")];
        spans.extend(line.spans);
        lines.push(Line::from(spans));
    }
    lines.push(Line::raw(""));

    let mut next = wrap(&topic.next, text_w).into_iter();
    if let Some(first) = next.next() {
        lines.push(field(
            theme,
            "NEXT",
            vec![Span::styled(first, theme.fg(theme.accent2))],
        ));
        for more in next {
            lines.push(field(
                theme,
                "",
                vec![Span::styled(more, theme.fg(theme.accent2))],
            ));
        }
    }

    if let Some(run) = app.active_run(topic).or_else(|| app.latest_run(topic)) {
        let mut spans = vec![
            run_glyph(app, run),
            Span::styled(
                format!(" {}", truncate(&run.command(), text_w.saturating_sub(14))),
                theme.fg(theme.text),
            ),
        ];
        let when = if run.state == RunState::Running {
            time::duration(run_elapsed(run, now))
        } else {
            time::since(run.ended_ms.unwrap_or(run.started_ms), now)
        };
        spans.push(Span::styled(format!(" · {when}"), theme.faint()));
        lines.push(field(theme, "RUN", spans));
        if !run.phases.is_empty() {
            lines.push(field(theme, "", phase_chips(app, run, text_w)));
        }
        let note = if run.state == RunState::Running {
            run.current_phase().map(|p| p.msg.clone())
        } else {
            run.summary.as_ref().map(|s| s.1.clone())
        };
        if let Some(note) = note.filter(|n| !n.is_empty()) {
            lines.push(field(
                theme,
                "",
                vec![Span::styled(truncate(&note, text_w), theme.muted())],
            ));
        }
    }

    let behind = match topic.behind {
        Some(0) => "on trunk's tip".to_string(),
        Some(n) => format!("{n} behind trunk"),
        None => format!("over {} behind trunk", crate::repo::TRUNK_DEPTH),
    };
    lines.push(field(
        theme,
        "STACK",
        vec![Span::styled(
            format!("{} above trunk · {behind}", topic.stack.len()),
            theme.muted(),
        )],
    ));
    for revision in topic.stack.iter().rev().take(6) {
        let mut spans = vec![
            Span::styled(revision.short.clone(), theme.fg(theme.purple)),
            Span::raw(" "),
        ];
        let impact = revision
            .impact
            .last()
            .cloned()
            .unwrap_or_else(|| "no impact".into());
        let right_w = width(&impact) + if revision.conflict { 11 } else { 0 } + 1;
        let title = if revision.title.is_empty() {
            "(no description)"
        } else {
            &revision.title
        };
        spans.push(Span::styled(
            truncate(title, text_w.saturating_sub(9 + right_w)),
            theme.fg(theme.text),
        ));
        spans.push(Span::raw(" "));
        spans.push(Span::styled(impact.clone(), impact_style(theme, &impact)));
        if revision.conflict {
            spans.push(Span::styled(" conflicted", theme.bold(theme.err)));
        }
        lines.push(field(theme, "", spans));
    }
    if topic.stack.len() > 6 {
        lines.push(field(
            theme,
            "",
            vec![Span::styled(
                format!("… {} more", topic.stack.len() - 6),
                theme.faint(),
            )],
        ));
    }

    let lint = match topic.lint {
        Lint::Passed { at_ms } => Span::styled(
            format!(
                "✔ passed on this head{}",
                at_ms
                    .map(|at| format!(" · {}", time::since(at, now)))
                    .unwrap_or_default()
            ),
            theme.fg(theme.ok),
        ),
        Lint::Stale => Span::styled(
            "stale: the head changed since the last preflight",
            theme.fg(theme.warn),
        ),
        Lint::Never => Span::styled("never run in this workspace", theme.faint()),
    };
    if !topic.idle {
        lines.push(field(theme, "LINT", vec![lint]));
    }

    match (&topic.branch, &topic.published_head) {
        (Some(branch), head) => {
            lines.push(field(
                theme,
                "BRANCH",
                vec![Span::styled(truncate(branch, text_w), theme.fg(theme.info))],
            ));
            let at = match head {
                Some(head) if *head == topic.head.commit_id => Span::styled(
                    format!("↑ {} on tangled, the current head", &head[..7]),
                    theme.muted(),
                ),
                Some(head) => Span::styled(
                    format!("↑ {} on tangled; the head has moved since", &head[..7]),
                    theme.fg(theme.warn),
                ),
                None => Span::styled("not on tangled", theme.faint()),
            };
            lines.push(field(theme, "", vec![at]));
        }
        (None, _) if !topic.idle => lines.push(field(
            theme,
            "BRANCH",
            vec![Span::styled("not dispatched", theme.faint())],
        )),
        _ => {}
    }

    if let Some(ci) = &topic.ci {
        let mut spans = vec![];
        let verdict = |name: &str, state: &str| {
            let style = match state {
                "success" => theme.fg(theme.ok),
                "failed" => theme.bold(theme.err),
                "running" | "in_progress" | "queued" => theme.fg(theme.warn),
                _ => theme.faint(),
            };
            Span::styled(format!("{name} {state}"), style)
        };
        if let Some(spindle) = &ci.spindle {
            spans.push(verdict("spindle", spindle));
        }
        if let Some(github) = &ci.github {
            spans.push(sep(theme));
            spans.push(verdict("GitHub", github));
        }
        if let Some(checked) = ci.checked_ms {
            spans.push(Span::styled(
                format!(" · checked {}", time::since(checked, now)),
                theme.faint(),
            ));
        }
        lines.push(field(theme, "CI", spans));
        if let Some(pull) = &ci.pull {
            lines.push(field(
                theme,
                "PR",
                vec![Span::styled(truncate(pull, text_w), theme.fg(theme.info))],
            ));
        }
    } else if topic.dispatched() {
        lines.push(field(
            theme,
            "CI",
            vec![Span::styled(
                "not checked yet · ␣ u asks the forges",
                theme.faint(),
            )],
        ));
    }

    if let Some(stranded) = &topic.stranded {
        lines.push(field(
            theme,
            "OFF",
            vec![Span::styled(
                truncate(
                    &format!(
                        "left {} \"{}\" for {}",
                        stranded.short, stranded.title, stranded.stray
                    ),
                    text_w,
                ),
                theme.fg(theme.err),
            )],
        ));
    }
    if topic.owner != "none" {
        let (text, style) = match topic.owner.as_str() {
            "active" => (
                "◆ an active Codex task owns this workspace",
                theme.fg(theme.info),
            ),
            "delivered" => ("delivered by its Codex task", theme.fg(theme.ok)),
            "discarded" => ("discarded by its Codex task", theme.faint()),
            _ => ("released by its Codex task", theme.faint()),
        };
        lines.push(field(theme, "OWNER", vec![Span::styled(text, style)]));
    }
    if let Some(holder) = app.topic_lock(topic) {
        lines.push(field(
            theme,
            "LOCK",
            vec![Span::styled(
                format!("held by ci pid {}", holder.pid),
                theme.fg(theme.warn),
            )],
        ));
    }
    if app.holds_checks(topic) {
        lines.push(field(
            theme,
            "CHECKS",
            vec![Span::styled(
                "this topic holds the machine's local checks",
                theme.fg(theme.warn),
            )],
        ));
    }
    if !topic.reviews.is_empty() {
        lines.push(field(
            theme,
            "REVIEW",
            vec![Span::styled(topic.reviews.join(" → "), theme.muted())],
        ));
    }
    if !topic.allowed.is_empty() {
        // The machine names model actions; say them in ci's own words.
        let steps: Vec<&str> = topic
            .allowed
            .iter()
            .map(|step| match *step {
                "validate" => "preflight",
                "publish" => "dispatch",
                "finish" => "park",
                "abandon" => "cancel",
                other => other,
            })
            .collect();
        lines.push(field(
            theme,
            "STEPS",
            vec![Span::styled(steps.join(" · "), theme.faint())],
        ));
    }
    if let Some(root) = &topic.root {
        lines.push(field(
            theme,
            "WHERE",
            vec![Span::styled(truncate(&tilde(root), text_w), theme.faint())],
        ));
    }
    frame.render_widget(Paragraph::new(lines), inner);
}

fn run_line(app: &App, run: &Run, w: usize) -> Line<'static> {
    let theme = &app.theme;
    let now = time::now_ms();
    let mut left = vec![Span::raw(" "), run_glyph(app, run), Span::raw(" ")];
    left.push(Span::styled(
        format!("ci {}", run.verb()),
        theme.bold(theme.text),
    ));
    left.push(sep(theme));
    left.push(Span::styled(
        app.workspace_name(&run.workspace),
        theme.muted(),
    ));
    left.push(sep(theme));
    match (run.state, run.current_phase(), &run.summary) {
        (RunState::Running, Some(phase), _) => {
            left.push(phase_glyph(app, run, phase));
            left.push(Span::styled(
                format!(" {}", phase.msg),
                theme.fg(theme.text),
            ));
        }
        (_, _, Some((state, msg))) => {
            let style = if *state == PhaseState::Error {
                theme.fg(theme.err)
            } else {
                theme.muted()
            };
            left.push(Span::styled(msg.clone(), style));
        }
        (RunState::Lost, _, _) => left.push(Span::styled(
            "ended without an exit code",
            theme.fg(theme.warn),
        )),
        (_, Some(phase), _) => left.push(Span::styled(phase.msg.clone(), theme.muted())),
        _ => {}
    }
    let right = if run.state == RunState::Running {
        Span::styled(
            format!("{} ", time::duration(run_elapsed(run, now))),
            theme.fg(theme.warn),
        )
    } else {
        Span::styled(
            format!(
                "{} ",
                time::since(run.ended_ms.unwrap_or(run.started_ms), now)
            ),
            theme.faint(),
        )
    };
    split_line(left, vec![right], w)
}

fn draw_run_strip(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let running = app
        .runs
        .iter()
        .filter(|r| r.state == RunState::Running)
        .count();
    let note = if running > 0 {
        format!(" {running} running ")
    } else {
        " 2 shows every run ".to_string()
    };
    let block = panel(theme, title_spans(theme, "Recent runs", false), false)
        .title_top(Line::from(Span::styled(note, theme.faint())).right_aligned());
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let lines: Vec<Line> = app
        .runs
        .iter()
        .take(inner.height as usize)
        .map(|run| run_line(app, run, inner.width as usize))
        .collect();
    frame.render_widget(Paragraph::new(lines), inner);
}

// ── runs ────────────────────────────────────────────────────────────────────

fn draw_runs(frame: &mut Frame, area: Rect, app: &App) {
    if app.zoom {
        draw_log(frame, area, app, true);
        return;
    }
    let (list, detail) = if area.width >= 100 {
        let [list, detail] =
            Layout::horizontal([Constraint::Percentage(38), Constraint::Percentage(62)])
                .areas(area);
        (list, detail)
    } else {
        let [list, detail] =
            Layout::vertical([Constraint::Percentage(40), Constraint::Percentage(60)]).areas(area);
        (list, detail)
    };
    draw_run_list(frame, list, app);
    draw_run_detail(frame, detail, app);
}

fn draw_run_list(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let runs = app.visible_runs();
    let running = runs.iter().filter(|r| r.state == RunState::Running).count();
    let mut block = panel(theme, title_spans(theme, "Runs", true), true).title_top(
        Line::from(Span::styled(
            format!(" {running} running · {} ", runs.len()),
            theme.faint(),
        ))
        .right_aligned(),
    );
    if !app.filter.is_empty() || matches!(app.mode, Mode::Filter) {
        let cursor = if matches!(app.mode, Mode::Filter) {
            "▏"
        } else {
            ""
        };
        block = block.title_bottom(Line::from(vec![
            Span::styled(" / ", theme.bold(theme.warn)),
            Span::styled(format!("{}{cursor} ", app.filter), theme.fg(theme.text)),
        ]));
    }
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if runs.is_empty() {
        let lines = vec![
            Line::raw(""),
            Line::from(Span::styled("No ci runs recorded yet.", theme.muted())),
            Line::from(Span::styled(
                "Runs from the ci MCP server, job-log, and ␣ appear here.",
                theme.faint(),
            )),
        ];
        frame.render_widget(Paragraph::new(lines).alignment(Alignment::Center), inner);
        return;
    }
    let now = time::now_ms();
    let w = inner.width as usize;
    let selected = app.selected_run().map(|r| r.id.clone());
    let mut lines = vec![];
    let mut range = (0, 0);
    for run in &runs {
        let is_selected = Some(&run.id) == selected.as_ref();
        let start = lines.len();
        let bar = if is_selected {
            Span::styled("▌", theme.fg(theme.accent))
        } else {
            Span::raw(" ")
        };
        let rest = run
            .args
            .iter()
            .skip(1)
            .cloned()
            .collect::<Vec<_>>()
            .join(" ");
        let left = vec![
            bar.clone(),
            Span::raw(" "),
            run_glyph(app, run),
            Span::raw(" "),
            Span::styled(
                format!("ci {}", run.verb()),
                if is_selected {
                    theme.bold(theme.text)
                } else {
                    theme.fg(theme.text)
                },
            ),
            Span::styled(
                if rest.is_empty() {
                    String::new()
                } else {
                    format!(" {rest}")
                },
                theme.faint(),
            ),
        ];
        let when = if run.state == RunState::Running {
            Span::styled(
                format!("{} ", time::duration(run_elapsed(run, now))),
                theme.fg(theme.warn),
            )
        } else {
            Span::styled(
                format!(
                    "{} ",
                    time::since(run.ended_ms.unwrap_or(run.started_ms), now)
                ),
                theme.faint(),
            )
        };
        lines.push(split_line(left, vec![when], w));
        let mut meta = vec![
            bar,
            Span::raw("   "),
            Span::styled(app.workspace_name(&run.workspace), theme.muted()),
        ];
        let status = match run.state {
            RunState::Running => run.current_phase().map(|p| {
                let style = if p.state == PhaseState::Permission {
                    theme.bold(theme.accent)
                } else {
                    theme.fg(theme.warn)
                };
                Span::styled(p.id.clone(), style)
            }),
            RunState::Failed => Some(Span::styled(
                run.failed_phase()
                    .map(|p| format!("{} failed", p.id))
                    .unwrap_or_else(|| format!("exit {}", run.exit_code.unwrap_or(1))),
                theme.fg(theme.err),
            )),
            RunState::Lost => Some(Span::styled("lost", theme.fg(theme.warn))),
            RunState::Succeeded => Some(Span::styled(
                format!("took {}", time::duration(run_elapsed(run, now))),
                theme.faint(),
            )),
        };
        if let Some(status) = status {
            meta.push(sep(theme));
            meta.push(status);
        }
        if run.source == crate::jobs::Source::Shell {
            meta.push(Span::styled(" · job-log", theme.faint()));
        }
        lines.push(Line::from(fit(meta, w)));
        if is_selected {
            for line in &mut lines[start..] {
                line.style = Style::default().bg(theme.selection);
            }
            range = (start, lines.len());
        }
    }
    let height = inner.height as usize;
    let mut offset = app.run_offset.get();
    if range.0 < offset {
        offset = range.0;
    }
    if range.1 > offset + height {
        offset = range.1 - height;
    }
    app.run_offset.set(offset);
    frame.render_widget(
        Paragraph::new(
            lines
                .into_iter()
                .skip(offset)
                .take(height)
                .collect::<Vec<_>>(),
        ),
        inner,
    );
}

fn draw_run_detail(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let Some(run) = app.selected_run() else {
        frame.render_widget(panel(theme, title_spans(theme, "Run", false), false), area);
        return;
    };
    let now = time::now_ms();
    let header = format!("{} · {}", run.command(), app.workspace_name(&run.workspace));
    let block = panel(
        theme,
        title_spans(
            theme,
            &truncate(&header, area.width.saturating_sub(6) as usize),
            false,
        ),
        false,
    );
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let w = inner.width as usize;

    let mut lines = vec![];
    let state = match run.state {
        RunState::Running => Line::from(vec![
            Span::styled(
                format!(" {} running ", spinner(app)),
                theme.bold(theme.warn),
            ),
            Span::styled(time::duration(run_elapsed(run, now)), theme.fg(theme.text)),
            Span::styled(
                format!(" · started {}", time::clock(run.started_ms)),
                theme.faint(),
            ),
            Span::styled(
                run.pid.map(|p| format!(" · pid {p}")).unwrap_or_default(),
                theme.faint(),
            ),
        ]),
        RunState::Succeeded => Line::from(vec![
            Span::styled(" ✔ succeeded ", theme.bold(theme.ok)),
            Span::styled(
                format!("in {}", time::duration(run_elapsed(run, now))),
                theme.fg(theme.text),
            ),
            Span::styled(
                format!(
                    " · {}",
                    time::since(run.ended_ms.unwrap_or(run.started_ms), now)
                ),
                theme.faint(),
            ),
        ]),
        RunState::Failed => Line::from(vec![
            Span::styled(
                format!(" ✗ failed, exit {} ", run.exit_code.unwrap_or(1)),
                theme.bold(theme.err),
            ),
            Span::styled(
                format!("after {}", time::duration(run_elapsed(run, now))),
                theme.fg(theme.text),
            ),
            Span::styled(
                format!(
                    " · {}",
                    time::since(run.ended_ms.unwrap_or(run.started_ms), now)
                ),
                theme.faint(),
            ),
        ]),
        RunState::Lost => Line::from(vec![
            Span::styled(" ? lost ", theme.bold(theme.warn)),
            Span::styled(
                "its process ended without recording an exit code",
                theme.muted(),
            ),
        ]),
    };
    lines.push(state);
    lines.push(Line::raw(""));
    let id_w = run
        .phases
        .iter()
        .map(|p| width(&p.id))
        .max()
        .unwrap_or(0)
        .clamp(6, 16);
    for phase in &run.phases {
        let duration = match (phase.started_ms, phase.ended_ms) {
            // A phase reported only once it was over has no length.
            (Some(start), Some(end)) if end > start => time::duration(end - start),
            (Some(start), None) if run.state == RunState::Running => time::duration(now - start),
            _ => String::new(),
        };
        let style = match phase.state {
            PhaseState::Error => theme.fg(theme.err),
            PhaseState::Done => theme.muted(),
            PhaseState::Permission => theme.bold(theme.accent),
            _ => theme.fg(theme.text),
        };
        let left = vec![
            Span::raw(" "),
            phase_glyph(app, run, phase),
            Span::styled(format!(" {:<id_w$} ", phase.id), theme.bold(theme.muted)),
            Span::styled(phase.msg.clone(), style),
        ];
        lines.push(split_line(
            left,
            vec![Span::styled(format!("{duration} "), theme.faint())],
            w,
        ));
    }
    if let Some((state, msg)) = &run.summary {
        let (glyph, style) = if *state == PhaseState::Error {
            ("✗", theme.bold(theme.err))
        } else {
            ("⚑", theme.bold(theme.ok))
        };
        lines.push(Line::from(vec![
            Span::raw(" "),
            Span::styled(format!("{glyph} {msg}"), style),
        ]));
    }
    if run.phases.is_empty() && run.summary.is_none() {
        lines.push(Line::from(Span::styled(
            " No phase reports; the log below is the whole story.",
            theme.faint(),
        )));
    }
    let top = (lines.len() as u16 + 1).min(inner.height / 2);
    let [head, log] = Layout::vertical([Constraint::Length(top), Constraint::Fill(1)]).areas(inner);
    frame.render_widget(Paragraph::new(lines), head);
    draw_log(frame, log, app, false);
}

fn draw_log(frame: &mut Frame, area: Rect, app: &App, zoomed: bool) {
    let theme = &app.theme;
    let following = app.log.scroll == 0;
    let status = if following {
        Span::styled(" ● following ", theme.fg(theme.ok))
    } else {
        Span::styled(
            format!(" ↑ {} lines back · f follows ", app.log.scroll),
            theme.fg(theme.warn),
        )
    };
    let title = if zoomed {
        let run = app
            .selected_run()
            .map(|r| format!("{} · {}", r.command(), app.workspace_name(&r.workspace)))
            .unwrap_or_default();
        title_spans(theme, &format!("Log · {run}"), true)
    } else {
        Line::from(Span::styled(" log ", theme.bold(theme.muted)))
    };
    let block = if zoomed {
        panel(theme, title, true)
    } else {
        Block::default()
            .borders(ratatui::widgets::Borders::TOP)
            .border_style(theme.fg(theme.border))
            .title(title)
    }
    .title_top(Line::from(status).right_aligned());
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let height = inner.height as usize;
    let selected = app.selected_run().map(|r| r.id.clone());
    if app.log.run != selected || app.log.lines.is_empty() {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(" (no output yet)", theme.faint()))),
            inner,
        );
        return;
    }
    let total = app.log.lines.len();
    let end = total.saturating_sub(app.log.scroll);
    let start = end.saturating_sub(height);
    let base = theme.fg(theme.text);
    let lines: Vec<Line> = app.log.lines[start..end]
        .iter()
        .map(|raw| {
            let mut line = ansi::line(raw, base);
            let lower = raw.to_lowercase();
            if line.spans.iter().all(|s| s.style == base) {
                if lower.contains("error") || lower.contains("failed") || lower.contains("refus") {
                    line = line.style(theme.fg(theme.err));
                } else if lower.contains("warning") || lower.contains("waiting") {
                    line = line.style(theme.fg(theme.warn));
                } else if lower.starts_with("landed")
                    || lower.contains("passed")
                    || lower.starts_with("released")
                {
                    line = line.style(theme.fg(theme.ok));
                }
            }
            let mut spans = vec![Span::raw(" ")];
            spans.extend(line.spans.iter().cloned().map(|s| {
                if s.style == base {
                    s.style(line.style)
                } else {
                    s
                }
            }));
            Line::from(spans)
        })
        .collect();
    frame.render_widget(Paragraph::new(lines), inner);
}

// ── trunk ───────────────────────────────────────────────────────────────────

fn draw_trunk(frame: &mut Frame, area: Rect, app: &App) {
    let (list, side) = if area.width >= 110 {
        let [list, side] =
            Layout::horizontal([Constraint::Percentage(62), Constraint::Percentage(38)])
                .areas(area);
        (list, side)
    } else {
        let [list, side] =
            Layout::vertical([Constraint::Percentage(60), Constraint::Percentage(40)]).areas(area);
        (list, side)
    };
    let theme = &app.theme;
    let now = time::now_ms();
    let block = panel(
        theme,
        title_spans(theme, "Trunk · main@tangled", true),
        true,
    );
    let inner = block.inner(list);
    frame.render_widget(block, list);
    let Some(snapshot) = &app.snapshot else {
        return;
    };
    let w = inner.width as usize;
    let height = inner.height as usize;
    let mut offset = app.trunk_offset.get();
    if app.trunk_index < offset {
        offset = app.trunk_index;
    }
    if app.trunk_index >= offset + height {
        offset = app.trunk_index + 1 - height;
    }
    app.trunk_offset.set(offset);
    let lines: Vec<Line> = snapshot
        .trunk
        .iter()
        .enumerate()
        .skip(offset)
        .take(height)
        .map(|(index, commit)| {
            let selected = index == app.trunk_index;
            let bar = if selected {
                Span::styled("▌", theme.fg(theme.accent))
            } else {
                Span::raw(" ")
            };
            let mut left = vec![
                bar,
                Span::raw(" "),
                Span::styled(commit.short.clone(), theme.fg(theme.purple)),
                Span::raw(" "),
            ];
            for tag in commit.tags.iter().filter(|t| is_release(t)) {
                left.push(Span::styled(
                    format!(" {tag} "),
                    Style::default()
                        .fg(theme.bar)
                        .bg(theme.accent)
                        .add_modifier(Modifier::BOLD),
                ));
                if app.host.verified.contains_key(tag) {
                    left.push(Span::styled("✔", theme.fg(theme.ok)));
                }
                left.push(Span::raw(" "));
            }
            left.push(Span::styled(
                commit.title.clone(),
                if selected {
                    theme.bold(theme.text)
                } else {
                    theme.fg(theme.text)
                },
            ));
            let impact = commit.impact.last().cloned().unwrap_or_default();
            let right = vec![
                Span::styled(impact.clone(), impact_style(theme, &impact)),
                Span::styled(
                    format!(" {:>4} ", time::ago(commit.time_ms, now)),
                    theme.faint(),
                ),
            ];
            let mut line = split_line(left, right, w);
            if selected {
                line.style = Style::default().bg(theme.selection);
            }
            line
        })
        .collect();
    frame.render_widget(Paragraph::new(lines), inner);
    draw_trunk_side(frame, side, app);
}

fn draw_trunk_side(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let now = time::now_ms();
    let block = panel(
        theme,
        title_spans(theme, &format!("Host · {}", app.host.hostname), false),
        false,
    );
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let text_w = (inner.width as usize).saturating_sub(10).max(10);
    let mut lines = vec![];
    let activated = match app.host.activated_ms {
        Some(at) => Span::styled(
            format!("activated {}", time::since(at, now)),
            theme.fg(theme.text),
        ),
        None => Span::styled(
            "no activation recorded for the running system",
            theme.faint(),
        ),
    };
    lines.push(field(theme, "SYSTEM", vec![activated]));
    if let Some(snapshot) = &app.snapshot {
        let releases: Vec<&String> = snapshot
            .trunk
            .iter()
            .flat_map(|c| c.tags.iter())
            .filter(|t| is_release(t))
            .collect();
        let verified = releases
            .iter()
            .take(10)
            .filter(|r| app.host.verified.contains_key(**r))
            .count();
        lines.push(field(
            theme,
            "VERIFY",
            vec![Span::styled(
                format!(
                    "{verified} of the last {} releases verified here",
                    releases.len().min(10)
                ),
                if verified > 0 {
                    theme.fg(theme.text)
                } else {
                    theme.faint()
                },
            )],
        ));
    }
    if app.host.queued > 0 {
        lines.push(field(
            theme,
            "OUTBOX",
            vec![Span::styled(
                format!("{} verifications not sent to homelab", app.host.queued),
                theme.fg(theme.warn),
            )],
        ));
    }
    lines.push(Line::raw(""));
    match &app.locks.checks {
        Some(holder) => {
            lines.push(field(
                theme,
                "CHECKS",
                vec![Span::styled(
                    format!(
                        "{} {} \"{}\"",
                        spinner(app),
                        holder.change(),
                        truncate(holder.title(), text_w.saturating_sub(12))
                    ),
                    theme.fg(theme.warn),
                )],
            ));
            let since = holder
                .since_ms
                .map(|s| format!(" · {}", time::duration(now - s)))
                .unwrap_or_default();
            lines.push(field(
                theme,
                "",
                vec![Span::styled(
                    format!("pid {}{since}", holder.pid),
                    theme.faint(),
                )],
            ));
            lines.push(field(
                theme,
                "",
                vec![Span::styled(
                    truncate(&tilde(std::path::Path::new(&holder.workspace)), text_w),
                    theme.faint(),
                )],
            ));
        }
        None => lines.push(field(
            theme,
            "CHECKS",
            vec![Span::styled("free", theme.faint())],
        )),
    }
    for (place, holder) in app.locks.landing.iter().enumerate() {
        let (label, color) = if place == 0 {
            ("LANDING", theme.warn)
        } else {
            ("QUEUED", theme.accent)
        };
        lines.push(field(
            theme,
            label,
            vec![Span::styled(
                truncate(
                    &format!(
                        "{} \"{}\" · pid {}",
                        holder.change(),
                        holder.title(),
                        holder.pid
                    ),
                    text_w,
                ),
                theme.fg(color),
            )],
        ));
    }
    for (_, holder) in &app.locks.topics {
        lines.push(field(
            theme,
            "MOVING",
            vec![Span::styled(
                truncate(
                    &format!(
                        "{} \"{}\" · pid {}",
                        holder.change(),
                        holder.title(),
                        holder.pid
                    ),
                    text_w,
                ),
                theme.fg(theme.warn),
            )],
        ));
    }
    if let Some(snapshot) = &app.snapshot {
        lines.push(Line::raw(""));
        lines.push(field(
            theme,
            "GRAPH",
            vec![Span::styled(
                format!(
                    "{} workspaces · read in {}ms · {} ago",
                    snapshot.workspace_roots.len(),
                    snapshot.took_ms,
                    time::ago(snapshot.taken_ms, now)
                ),
                theme.faint(),
            )],
        ));
        if let Some(commit) = snapshot.trunk.get(app.trunk_index) {
            lines.push(Line::raw(""));
            for line in wrap(&commit.title, (inner.width as usize).saturating_sub(2))
                .into_iter()
                .take(3)
            {
                lines.push(Line::from(Span::styled(
                    format!(" {line}"),
                    theme.bold(theme.text),
                )));
            }
            lines.push(field(
                theme,
                "COMMIT",
                vec![Span::styled(
                    commit.commit_id[..12.min(commit.commit_id.len())].to_string(),
                    theme.fg(theme.accent2),
                )],
            ));
            lines.push(field(
                theme,
                "CHANGE",
                vec![Span::styled(commit.short.clone(), theme.fg(theme.purple))],
            ));
            lines.push(field(
                theme,
                "BY",
                vec![Span::styled(
                    format!("{} · {} ago", commit.author, time::ago(commit.time_ms, now)),
                    theme.muted(),
                )],
            ));
            if let Some(impact) = commit.impact.last() {
                lines.push(field(
                    theme,
                    "IMPACT",
                    vec![Span::styled(impact.clone(), impact_style(theme, impact))],
                ));
            }
            for tag in commit.tags.iter().filter(|t| is_release(t)) {
                let verified = app
                    .host
                    .verified
                    .get(tag)
                    .map(|at| format!(" · verified {}", time::since(*at, now)))
                    .unwrap_or_else(|| " · not verified here".into());
                lines.push(field(
                    theme,
                    "RELEASE",
                    vec![Span::styled(
                        format!("{tag}{verified}"),
                        theme.fg(theme.accent),
                    )],
                ));
            }
        }
    }
    frame.render_widget(Paragraph::new(lines), inner);
}

// ── chrome ──────────────────────────────────────────────────────────────────

fn hints(app: &App) -> Vec<(&'static str, &'static str)> {
    match &app.mode {
        Mode::Filter => vec![
            ("type", "filter"),
            ("⏎", "keep"),
            ("esc", "clear"),
            ("↑↓", "move"),
            ("^u", "erase"),
        ],
        Mode::Action => vec![
            ("p", "preflight"),
            ("d", "dispatch"),
            ("l", "land"),
            ("P", "park"),
            ("r", "rebase"),
            ("c", "conflicts"),
            ("s", "sequence"),
            ("u", "pipeline"),
            ("o", "jjui"),
            ("X", "cancel"),
            ("x", "stop run"),
            ("␣/esc", "back"),
        ],
        Mode::Confirm(_) => vec![("y", "run it"), ("n/esc", "back")],
        Mode::Help => vec![("esc/?", "close")],
        Mode::Normal => match app.view {
            View::Board => vec![
                ("j/k", "move"),
                ("␣", "actions"),
                ("⏎", "runs"),
                ("/", "filter"),
                ("i", "idle"),
                ("y", "yank id"),
                ("⇥", "view"),
                ("r", "reread"),
                ("?", "help"),
                ("q", "quit"),
            ],
            View::Runs if app.zoom => vec![
                ("PgUp/PgDn", "scroll"),
                ("f", "follow"),
                ("⏎/esc", "unzoom"),
                ("␣", "actions"),
                ("?", "help"),
                ("q", "quit"),
            ],
            View::Runs => vec![
                ("j/k", "move"),
                ("⏎", "zoom log"),
                ("PgUp/PgDn", "scroll"),
                ("f", "follow"),
                ("␣", "actions"),
                ("/", "filter"),
                ("y", "yank id"),
                ("⇥", "view"),
                ("?", "help"),
                ("q", "quit"),
            ],
            View::Trunk => vec![
                ("j/k", "move"),
                ("y", "yank commit"),
                ("⇥", "view"),
                ("r", "reread"),
                ("?", "help"),
                ("q", "quit"),
            ],
        },
    }
}

fn mode_color(theme: &Theme, mode: &Mode) -> Color {
    match mode {
        Mode::Normal => theme.accent2,
        Mode::Filter => theme.warn,
        Mode::Action => theme.accent,
        Mode::Confirm(_) => theme.err,
        Mode::Help => theme.purple,
    }
}

fn draw_hints(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let bar = Style::default().bg(theme.bar);
    let mut spans = vec![
        Span::styled(
            format!(" {} ", app.mode.name()),
            Style::default()
                .fg(theme.bar)
                .bg(mode_color(theme, &app.mode))
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
    ];
    let right = match &app.snapshot {
        Some(snapshot) => vec![Span::styled(
            format!("graph {} ", time::ago(snapshot.taken_ms, time::now_ms())),
            theme.faint(),
        )],
        None => vec![Span::styled(
            format!("{} reading ", spinner(app)),
            theme.faint(),
        )],
    };
    let room = (area.width as usize).saturating_sub(spans_width(&spans) + spans_width(&right) + 1);
    let mut used = 0;
    for (key, label) in hints(app) {
        let w = width(key) + width(label) + 3;
        if used + w > room {
            break;
        }
        spans.push(Span::styled(key, theme.bold(theme.accent2)));
        spans.push(Span::styled(format!(" {label}  "), theme.muted()));
        used += w;
    }
    frame.render_widget(
        Paragraph::new(split_line(spans, right, area.width as usize)).style(bar),
        area,
    );
}

fn centered(area: Rect, w: u16, h: u16) -> Rect {
    let w = w.min(area.width.saturating_sub(2));
    let h = h.min(area.height.saturating_sub(2));
    Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    )
}

fn dim(frame: &mut Frame, area: Rect) {
    frame
        .buffer_mut()
        .set_style(area, Style::default().add_modifier(Modifier::DIM));
}

fn draw_actions(frame: &mut Frame, body: Rect, app: &App) {
    let theme = &app.theme;
    let actions: Vec<Action> = Action::MENU
        .iter()
        .copied()
        .filter(|a| *a != Action::StopRun || app.view == View::Runs)
        .collect();
    let target = match app.view {
        View::Runs => app.selected_run().map(|r| app.workspace_name(&r.workspace)),
        _ => app.selected_topic().and_then(|t| t.workspace.clone()),
    };
    let w = 70.min(body.width.saturating_sub(2));
    let h = actions.len() as u16 + 4;
    let area = Rect::new(
        body.x + (body.width.saturating_sub(w)) / 2,
        body.y + body.height.saturating_sub(h),
        w,
        h.min(body.height),
    );
    frame.render_widget(Clear, area);
    let title = format!("Actions · {}", target.as_deref().unwrap_or("no workspace"));
    let block =
        panel(theme, title_spans(theme, &title, true), true).style(Style::default().bg(theme.bar));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let mut lines = vec![Line::raw("")];
    for action in actions {
        let available = !action.needs_workspace() || target.is_some();
        let key_style = if !available {
            theme.faint()
        } else if matches!(action, Action::Cancel | Action::StopRun) {
            theme.bold(theme.err)
        } else if action.confirms() {
            theme.bold(theme.warn)
        } else {
            theme.bold(theme.accent2)
        };
        let label_style = if available {
            theme.fg(theme.text)
        } else {
            theme.faint()
        };
        lines.push(Line::from(fit(
            vec![
                Span::styled(format!("  {}  ", action.key()), key_style),
                Span::styled(format!("{:<15}", action.label()), label_style),
                Span::styled(action.about(), theme.faint()),
            ],
            inner.width as usize,
        )));
    }
    frame.render_widget(Paragraph::new(lines), inner);
}

fn draw_confirm(frame: &mut Frame, area: Rect, app: &App) {
    let Mode::Confirm(pending) = &app.mode else {
        return;
    };
    let theme = &app.theme;
    dim(frame, area);
    let w = 68u16;
    let text_w = w as usize - 6;
    let mut lines = vec![Line::raw("")];
    let command = match pending.action.args() {
        Some(args) => format!("ci {}", args.join(" ")),
        None => pending.action.label().trim_end_matches('…').to_string(),
    };
    lines.push(Line::from(vec![
        Span::raw("  "),
        Span::styled(command, theme.bold(theme.text)),
    ]));
    if let Some(target) = &pending.target {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(format!("in {}", target.workspace), theme.fg(theme.accent2)),
        ]));
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(truncate(&target.topic, text_w), theme.fg(theme.purple)),
        ]));
    }
    if let Some(run) = &pending.run {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(run.clone(), theme.fg(theme.purple)),
        ]));
    }
    lines.push(Line::raw(""));
    let about = match pending.action {
        Action::Dispatch => "Rebases onto main@tangled, runs preflight, and pushes the topic branch to Tangled.",
        Action::Land => "Dispatches, builds every flake check on this machine (holding the local checks lock), then fast-forwards main on Tangled and GitHub and tags any release.",
        Action::Park => "Checks that the topic landed, deletes its branch, and frees the workspace.",
        Action::Cancel => "Deletes the topic branch and abandons its revisions above trunk. `ci recover` with the printed checkpoint recovers it.",
        Action::StopRun => "Sends SIGTERM to the run's process group. ci checkpoints before history surgery; inspect the workspace afterwards.",
        other => other.about(),
    };
    for line in wrap(about, text_w) {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(line, theme.muted()),
        ]));
    }
    for warning in &pending.warnings {
        lines.push(Line::raw(""));
        for (index, line) in wrap(warning, text_w - 2).into_iter().enumerate() {
            let lead = if index == 0 { "⚠ " } else { "  " };
            lines.push(Line::from(vec![
                Span::raw("  "),
                Span::styled(format!("{lead}{line}"), theme.fg(theme.warn)),
            ]));
        }
    }
    lines.push(Line::raw(""));
    lines.push(Line::from(vec![
        Span::raw("  "),
        Span::styled(
            " y ",
            Style::default()
                .fg(theme.bar)
                .bg(theme.ok)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(" run it     ", theme.fg(theme.text)),
        Span::styled(
            " n ",
            Style::default()
                .fg(theme.bar)
                .bg(theme.faint)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(" back", theme.fg(theme.text)),
    ]));
    let rect = centered(area, w, lines.len() as u16 + 3);
    frame.render_widget(Clear, rect);
    let danger = matches!(
        pending.action,
        Action::Cancel | Action::StopRun | Action::Land
    );
    let block = Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(theme.fg(if danger { theme.err } else { theme.warn }))
        .title(title_spans(
            theme,
            &format!("{}?", pending.action.label().trim_end_matches('…')),
            true,
        ))
        .style(Style::default().bg(theme.bar));
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    frame.render_widget(Paragraph::new(lines), inner);
}

fn draw_help(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    dim(frame, area);
    let key = |k: &str, what: &str| {
        Line::from(vec![
            Span::styled(format!("  {k:<13}"), theme.bold(theme.accent2)),
            Span::styled(what.to_string(), theme.fg(theme.text)),
        ])
    };
    let head = |text: &str| Line::from(Span::styled(format!(" {text}"), theme.bold(theme.accent)));
    let mut lines = vec![
        Line::raw(""),
        head("NORMAL — every view"),
        key("j k ↑ ↓", "move the selection; g G jump to the ends"),
        key("⇥ ⇤ 1 2 3", "switch view: Board, Runs, Trunk"),
        key("␣", "ACTION mode: run a ci step for the selection"),
        key("/", "FILTER mode: narrow topics or runs"),
        key("y Y", "copy the change id / the path (OSC 52)"),
        key("r", "read the graph again now"),
        key("q ^c", "quit; runs keep going without the tower"),
        Line::raw(""),
        head("BOARD"),
        key("⏎", "open the topic's latest run"),
        key("i", "show or hide idle workspaces"),
        Line::raw(""),
        head("RUNS"),
        key("⏎", "zoom the log; esc unzooms"),
        key("PgUp PgDn", "scroll the log; f follows it again"),
        Line::raw(""),
        head("MODES"),
        key("esc", "back to NORMAL from any mode"),
        key("␣ / ? again", "leave the mode the key entered"),
        Line::raw(""),
        head("STAGES"),
    ];
    let stages = [
        (Stage::Editing, "editing"),
        (Stage::Validated, "preflight passed on this head"),
        (Stage::Published, "dispatched to Tangled"),
        (Stage::Republish, "edited since its dispatch"),
        (Stage::Passed, "a pipeline cleared the head"),
        (Stage::Failed, "a pipeline rejected the head"),
        (Stage::Landed, "on main; park it"),
        (Stage::Stranded, "the working copy left the topic"),
    ];
    let label_w = stages
        .iter()
        .map(|(stage, _)| width(stage_label(*stage)))
        .max()
        .unwrap_or(0)
        + 2;
    for (stage, what) in stages {
        lines.push(Line::from(vec![
            Span::styled(
                format!("  {}  ", stage_glyph(stage)),
                theme.bold(theme.stage_color(stage)),
            ),
            Span::styled(
                format!("{:<label_w$}", stage_label(stage)),
                theme.fg(theme.stage_color(stage)),
            ),
            Span::styled(what.to_string(), theme.muted()),
        ]));
    }
    let rect = centered(area, 70, lines.len() as u16 + 3);
    frame.render_widget(Clear, rect);
    let block = panel(theme, title_spans(theme, "ci tower · keys", true), true)
        .style(Style::default().bg(theme.bar));
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    frame.render_widget(
        Paragraph::new(Text::from(lines)).wrap(Wrap { trim: false }),
        inner,
    );
}

fn draw_toast(frame: &mut Frame, body: Rect, app: &App) {
    let Some(toast) = &app.toast else { return };
    let theme = &app.theme;
    let (glyph, color) = match toast.level {
        Level::Info => ("•", theme.accent2),
        Level::Ok => ("✔", theme.ok),
        Level::Warn => ("⚠", theme.warn),
        Level::Error => ("✗", theme.err),
    };
    let text = truncate(&toast.text, body.width.saturating_sub(10) as usize);
    let w = (width(&text) + 6) as u16;
    // Inside the panels' bottom-right corner, clear of their borders.
    let rect = Rect::new(
        body.x + body.width.saturating_sub(w + 2),
        body.y + body.height.saturating_sub(4),
        w.min(body.width),
        3.min(body.height),
    );
    frame.render_widget(Clear, rect);
    let block = Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(theme.fg(color))
        .style(Style::default().bg(theme.bar));
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(format!(" {glyph} "), theme.bold(color)),
            Span::styled(text, theme.fg(theme.text)),
        ])),
        inner,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_records_sit_at_clearance() {
        assert_eq!(phase_station("clearance"), 3);
        assert_eq!(phase_station("clearance/den-host-evaluation"), 3);
        assert_eq!(phase_station("land"), 4);
    }
}
