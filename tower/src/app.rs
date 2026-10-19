//! The tower's state and its keymap. Every mode shows its keys in the hint
//! bar; Esc, or the key that entered a mode, returns to Normal.

use std::cell::Cell;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use jj_ci_lifecycle::stage::Stage;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use crate::feed::Feed;
use crate::host::{HostInfo, Locks};
use crate::jobs::{self, Run, RunState};
use crate::repo::{Snapshot, Topic};
use crate::theme::Theme;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum View {
    Board,
    Runs,
    Trunk,
}

impl View {
    pub const ALL: [View; 3] = [View::Board, View::Runs, View::Trunk];

    pub fn title(self) -> &'static str {
        match self {
            View::Board => "Board",
            View::Runs => "Runs",
            View::Trunk => "Trunk",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Preflight,
    Dispatch,
    Rebase,
    Conflicts,
    Sequence,
    Land,
    Park,
    Cancel,
    RefreshCi,
    Dashboard,
    StopRun,
}

impl Action {
    pub const MENU: [Action; 11] = [
        Action::Preflight,
        Action::Dispatch,
        Action::Land,
        Action::Park,
        Action::Rebase,
        Action::Conflicts,
        Action::Sequence,
        Action::RefreshCi,
        Action::Dashboard,
        Action::Cancel,
        Action::StopRun,
    ];

    pub fn key(self) -> char {
        match self {
            Action::Preflight => 'p',
            Action::Dispatch => 'd',
            Action::Rebase => 'r',
            Action::Conflicts => 'c',
            Action::Sequence => 's',
            Action::Land => 'l',
            Action::Park => 'P',
            Action::Cancel => 'X',
            Action::RefreshCi => 'u',
            Action::Dashboard => 'o',
            Action::StopRun => 'x',
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Action::Preflight => "preflight",
            Action::Dispatch => "dispatch",
            Action::Rebase => "rebase",
            Action::Conflicts => "conflicts",
            Action::Sequence => "sequence",
            Action::Land => "land…",
            Action::Park => "park…",
            Action::Cancel => "cancel topic…",
            Action::RefreshCi => "pipeline state",
            Action::Dashboard => "jjui",
            Action::StopRun => "stop run…",
        }
    }

    pub fn about(self) -> &'static str {
        match self {
            Action::Preflight => "format and Prek gates on this change",
            Action::Dispatch => "rebase, preflight, push the topic branch",
            Action::Rebase => "fetch trunk and rebase the topic in place",
            Action::Conflicts => "list conflicted revisions and files",
            Action::Sequence => "trial-merge in-flight topics, propose stacks",
            Action::Land => "clear the head locally, fast-forward main",
            Action::Park => "confirm the landing, free the workspace",
            Action::Cancel => "delete the branch, abandon the topic",
            Action::RefreshCi => "re-read GitHub and the PR",
            Action::Dashboard => "open the workspace in the JJ dashboard",
            Action::StopRun => "SIGTERM the selected run",
        }
    }

    /// The `ci` arguments, for actions that run `ci`.
    pub fn args(self) -> Option<Vec<String>> {
        let args: &[&str] = match self {
            Action::Preflight => &["preflight"],
            Action::Dispatch => &["dispatch"],
            Action::Rebase => &["rebase"],
            Action::Conflicts => &["conflicts"],
            Action::Sequence => &["sequence"],
            Action::Land => &["land", "--clearance", "local"],
            Action::Park => &["park"],
            Action::Cancel => &["cancel"],
            _ => return None,
        };
        Some(args.iter().map(|a| a.to_string()).collect())
    }

    pub fn mutating(self) -> bool {
        !matches!(
            self,
            Action::Conflicts | Action::Sequence | Action::RefreshCi | Action::Dashboard
        )
    }

    /// Whether the action reaches outside this machine or cannot be undone
    /// with `jj op restore`, and so asks first.
    pub fn confirms(self) -> bool {
        matches!(
            self,
            Action::Dispatch | Action::Land | Action::Park | Action::Cancel | Action::StopRun
        )
    }

    /// Whether it acts on a workspace (all but stopping a run).
    pub fn needs_workspace(self) -> bool {
        !matches!(self, Action::StopRun)
    }
}

#[derive(Clone, Debug)]
pub struct Target {
    pub workspace: String,
    pub root: PathBuf,
    pub topic: String,
    pub owner: String,
}

#[derive(Clone, Debug)]
pub struct Pending {
    pub action: Action,
    pub target: Option<Target>,
    pub run: Option<String>,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug)]
pub enum Mode {
    Normal,
    Filter,
    Action,
    Confirm(Pending),
    Help,
}

impl Mode {
    pub fn name(&self) -> &'static str {
        match self {
            Mode::Normal => "NORMAL",
            Mode::Filter => "FILTER",
            Mode::Action => "ACTION",
            Mode::Confirm(_) => "CONFIRM",
            Mode::Help => "HELP",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Info,
    Ok,
    Warn,
    Error,
}

pub struct Toast {
    pub text: String,
    pub level: Level,
    pub until: Instant,
}

/// Where a topic sits on the board.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Group {
    Active,
    Attention,
    Dispatched,
    Working,
    Landed,
    Idle,
}

impl Group {
    pub fn title(self) -> &'static str {
        match self {
            Group::Active => "IN FLIGHT",
            Group::Attention => "NEEDS ATTENTION",
            Group::Dispatched => "DISPATCHED",
            Group::Working => "ON THE GROUND",
            Group::Landed => "LANDED · PARK PENDING",
            Group::Idle => "IDLE",
        }
    }
}

pub struct LogView {
    pub run: Option<String>,
    pub lines: Vec<String>,
    /// Lines up from the bottom; 0 follows the end.
    pub scroll: usize,
}

const LOG_LIMIT: usize = 20_000;

pub struct App {
    pub theme: Theme,
    pub ci: String,
    pub feed: Option<Feed>,
    pub view: View,
    pub mode: Mode,
    pub filter: String,
    pub show_idle: bool,
    pub zoom: bool,
    pub snapshot: Option<Snapshot>,
    pub snapshot_error: Option<String>,
    pub runs: Vec<Run>,
    pub locks: Locks,
    pub host: HostInfo,
    pub board_key: Option<String>,
    pub board_index: usize,
    pub run_id: Option<String>,
    pub run_index: usize,
    pub trunk_index: usize,
    pub log: LogView,
    pub toast: Option<Toast>,
    pub frame: usize,
    pub quit: bool,
    pub loads: usize,
    /// First visible line of each list, kept between frames so scrolling
    /// moves only as far as the selection needs.
    pub board_offset: Cell<usize>,
    pub run_offset: Cell<usize>,
    pub trunk_offset: Cell<usize>,
}

impl App {
    pub fn new(theme: Theme, ci: String, feed: Option<Feed>) -> Self {
        App {
            theme,
            ci,
            feed,
            view: View::Board,
            mode: Mode::Normal,
            filter: String::new(),
            show_idle: false,
            zoom: false,
            snapshot: None,
            snapshot_error: None,
            runs: vec![],
            locks: Locks::default(),
            host: HostInfo::default(),
            board_key: None,
            board_index: 0,
            run_id: None,
            run_index: 0,
            trunk_index: 0,
            log: LogView {
                run: None,
                lines: vec![],
                scroll: 0,
            },
            toast: None,
            frame: 0,
            quit: false,
            loads: 0,
            board_offset: Cell::new(0),
            run_offset: Cell::new(0),
            trunk_offset: Cell::new(0),
        }
    }

    pub fn toast(&mut self, level: Level, text: impl Into<String>) {
        self.toast = Some(Toast {
            text: text.into(),
            level,
            until: Instant::now() + Duration::from_millis(4_500),
        });
    }

    pub fn set_snapshot(&mut self, snapshot: Snapshot) {
        self.snapshot = Some(snapshot);
        self.snapshot_error = None;
        self.loads += 1;
        // Open on this workspace's topic when it has one, else on the most
        // urgent row, which is first.
        if self.board_key.is_none() {
            let board = self.board();
            let key = board
                .iter()
                .find(|(group, topic)| topic.current && *group != Group::Idle)
                .or(board.first())
                .map(|(_, topic)| topic.key.clone());
            self.board_key = key;
        }
    }

    pub fn append_log(&mut self, run: String, lines: Vec<String>, reset: bool) {
        if reset || self.log.run.as_ref() != Some(&run) {
            self.log.lines.clear();
            self.log.scroll = 0;
            self.log.run = Some(run);
        }
        let added = lines.len();
        self.log.lines.extend(lines);
        if self.log.lines.len() > LOG_LIMIT {
            let excess = self.log.lines.len() - LOG_LIMIT;
            self.log.lines.drain(..excess);
        }
        // Keep a scrolled-back view in place while lines arrive.
        if self.log.scroll > 0 {
            self.log.scroll += added;
        }
    }

    /// Whether anything on screen moves on its own, so frames keep coming.
    pub fn animating(&self) -> bool {
        self.snapshot.is_none()
            || self.runs.iter().any(|r| r.state == RunState::Running)
            || self.locks.checks.is_some()
            || self.toast.is_some()
    }

    pub fn active_run(&self, topic: &Topic) -> Option<&Run> {
        let root = topic.root.as_ref()?;
        self.runs
            .iter()
            .find(|run| run.state == RunState::Running && &run.workspace == root)
    }

    pub fn latest_run(&self, topic: &Topic) -> Option<&Run> {
        let root = topic.root.as_ref()?;
        self.runs.iter().find(|run| &run.workspace == root)
    }

    pub fn topic_lock(&self, topic: &Topic) -> Option<&crate::host::Holder> {
        self.locks
            .topics
            .iter()
            .find(|(change, _)| *change == topic.head.change_id)
            .map(|(_, holder)| holder)
    }

    pub fn holds_checks(&self, topic: &Topic) -> bool {
        self.locks.checks.as_ref().is_some_and(|holder| {
            topic
                .root
                .as_ref()
                .is_some_and(|root| root.to_string_lossy() == holder.workspace)
                || topic.head.change_id.starts_with(holder.change())
        })
    }

    pub fn group(&self, topic: &Topic) -> Group {
        if self.active_run(topic).is_some() || self.topic_lock(topic).is_some() {
            return Group::Active;
        }
        let failed_since = self.latest_run(topic).is_some_and(|run| {
            matches!(run.state, RunState::Failed | RunState::Lost)
                && run.ended_ms.unwrap_or(run.started_ms) > topic.head.time_ms
        });
        if failed_since && !topic.idle && topic.stage != Stage::Finished {
            return Group::Attention;
        }
        match topic.stage {
            Stage::Failed | Stage::Stranded => Group::Attention,
            _ if !topic.conflicts.is_empty() => Group::Attention,
            Stage::Published | Stage::Passed | Stage::Republish => Group::Dispatched,
            Stage::Editing | Stage::Validated => Group::Working,
            Stage::Landed => Group::Landed,
            Stage::Finished | Stage::Idle => Group::Idle,
        }
    }

    fn matches(&self, haystack: &[&str]) -> bool {
        if self.filter.is_empty() {
            return true;
        }
        let needle = self.filter.to_lowercase();
        haystack.iter().any(|h| h.to_lowercase().contains(&needle))
    }

    /// The board's topics in display order, grouped.
    pub fn board(&self) -> Vec<(Group, &Topic)> {
        let Some(snapshot) = &self.snapshot else {
            return vec![];
        };
        let mut rows: Vec<(Group, &Topic)> = snapshot
            .topics
            .iter()
            .map(|topic| (self.group(topic), topic))
            .filter(|(group, topic)| self.show_idle || *group != Group::Idle || topic.current)
            .filter(|(_, topic)| {
                self.matches(&[
                    topic.workspace.as_deref().unwrap_or(""),
                    &topic.head.title,
                    &topic.head.change_id,
                    topic.branch.as_deref().unwrap_or(""),
                ])
            })
            .collect();
        rows.sort_by_key(|(group, _)| *group);
        rows
    }

    pub fn hidden_idle(&self) -> usize {
        let Some(snapshot) = &self.snapshot else {
            return 0;
        };
        if self.show_idle {
            return 0;
        }
        snapshot
            .topics
            .iter()
            .filter(|t| self.group(t) == Group::Idle && !t.current)
            .count()
    }

    pub fn selected_topic(&self) -> Option<&Topic> {
        let board = self.board();
        let index = self.board_selection(&board)?;
        board.get(index).map(|(_, topic)| *topic)
    }

    pub fn board_selection(&self, board: &[(Group, &Topic)]) -> Option<usize> {
        if board.is_empty() {
            return None;
        }
        self.board_key
            .as_ref()
            .and_then(|key| board.iter().position(|(_, t)| &t.key == key))
            .or(Some(self.board_index.min(board.len() - 1)))
    }

    pub fn visible_runs(&self) -> Vec<&Run> {
        self.runs
            .iter()
            .filter(|run| {
                let workspace = run
                    .workspace
                    .file_name()
                    .map(|n| n.to_string_lossy())
                    .unwrap_or_default();
                self.matches(&[&run.command(), &workspace, &run.id])
            })
            .collect()
    }

    pub fn selected_run(&self) -> Option<&Run> {
        let runs = self.visible_runs();
        if runs.is_empty() {
            return None;
        }
        let index = self
            .run_id
            .as_ref()
            .and_then(|id| runs.iter().position(|r| &r.id == id))
            .unwrap_or(self.run_index.min(runs.len() - 1));
        runs.get(index).copied()
    }

    pub fn workspace_name(&self, root: &std::path::Path) -> String {
        self.snapshot
            .as_ref()
            .and_then(|s| s.topics.iter().find(|t| t.root.as_deref() == Some(root)))
            .and_then(|t| t.workspace.clone())
            .unwrap_or_else(|| {
                root.file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default()
            })
    }

    /// Points the log tail at the selected run in the Runs view.
    pub fn sync_follow(&mut self) {
        let target = if self.view == View::Runs {
            self.selected_run()
                .map(|run| (run.id.clone(), run.log.clone()))
        } else {
            None
        };
        if let Some(feed) = &self.feed {
            feed.follow(target);
        }
    }

    fn move_selection(&mut self, delta: isize) {
        match self.view {
            View::Board => {
                let board = self.board();
                let Some(current) = self.board_selection(&board) else {
                    return;
                };
                let next = (current as isize + delta).clamp(0, board.len() as isize - 1) as usize;
                self.board_key = Some(board[next].1.key.clone());
                self.board_index = next;
            }
            View::Runs => {
                let runs = self.visible_runs();
                if runs.is_empty() {
                    return;
                }
                let current = self
                    .run_id
                    .as_ref()
                    .and_then(|id| runs.iter().position(|r| &r.id == id))
                    .unwrap_or(self.run_index.min(runs.len() - 1));
                let next = (current as isize + delta).clamp(0, runs.len() as isize - 1) as usize;
                self.run_id = Some(runs[next].id.clone());
                self.run_index = next;
                self.log.scroll = 0;
            }
            View::Trunk => {
                let len = self.snapshot.as_ref().map_or(0, |s| s.trunk.len());
                if len > 0 {
                    self.trunk_index =
                        (self.trunk_index as isize + delta).clamp(0, len as isize - 1) as usize;
                }
            }
        }
    }

    fn set_view(&mut self, view: View) {
        self.view = view;
        self.zoom = false;
    }

    fn cycle_view(&mut self, step: isize) {
        let index = View::ALL.iter().position(|v| *v == self.view).unwrap_or(0) as isize;
        let next = (index + step).rem_euclid(View::ALL.len() as isize) as usize;
        self.set_view(View::ALL[next]);
    }

    fn scroll_log(&mut self, delta: isize) {
        let max = self.log.lines.len();
        self.log.scroll = (self.log.scroll as isize + delta).clamp(0, max as isize) as usize;
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        if key.kind == KeyEventKind::Release {
            return;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if ctrl && key.code == KeyCode::Char('c') {
            self.quit = true;
            return;
        }
        match self.mode.clone() {
            Mode::Normal => self.normal_key(key, ctrl),
            Mode::Filter => match key.code {
                KeyCode::Esc => {
                    self.filter.clear();
                    self.mode = Mode::Normal;
                }
                KeyCode::Enter => self.mode = Mode::Normal,
                KeyCode::Backspace => {
                    self.filter.pop();
                }
                KeyCode::Char('u') if ctrl => self.filter.clear(),
                KeyCode::Char(c) if !ctrl => self.filter.push(c),
                KeyCode::Down => self.move_selection(1),
                KeyCode::Up => self.move_selection(-1),
                _ => {}
            },
            Mode::Action => match key.code {
                KeyCode::Esc | KeyCode::Char(' ') => self.mode = Mode::Normal,
                KeyCode::Char(c) => {
                    if let Some(action) = Action::MENU.iter().copied().find(|a| a.key() == c) {
                        self.mode = Mode::Normal;
                        self.request(action);
                    }
                }
                _ => {}
            },
            Mode::Confirm(pending) => match key.code {
                KeyCode::Char('y') | KeyCode::Char('Y') => {
                    self.mode = Mode::Normal;
                    self.perform(&pending);
                }
                KeyCode::Char('n') | KeyCode::Esc => {
                    self.mode = Mode::Normal;
                    self.toast(Level::Info, "Nothing started.");
                }
                _ => {}
            },
            Mode::Help => {
                if matches!(
                    key.code,
                    KeyCode::Esc | KeyCode::Char('?') | KeyCode::Char('q')
                ) {
                    self.mode = Mode::Normal;
                }
            }
        }
        self.sync_follow();
    }

    fn normal_key(&mut self, key: KeyEvent, ctrl: bool) {
        match key.code {
            KeyCode::Char('q') => self.quit = true,
            KeyCode::Esc => {
                if self.zoom {
                    self.zoom = false;
                } else if !self.filter.is_empty() {
                    self.filter.clear();
                }
            }
            KeyCode::Tab => self.cycle_view(1),
            KeyCode::BackTab => self.cycle_view(-1),
            KeyCode::Char('1') => self.set_view(View::Board),
            KeyCode::Char('2') => self.set_view(View::Runs),
            KeyCode::Char('3') => self.set_view(View::Trunk),
            KeyCode::Char('j') | KeyCode::Down => self.move_selection(1),
            KeyCode::Char('k') | KeyCode::Up => self.move_selection(-1),
            KeyCode::Char('g') | KeyCode::Home => self.move_selection(-100_000),
            KeyCode::Char('G') | KeyCode::End => self.move_selection(100_000),
            KeyCode::Char('d') if ctrl => self.page(1),
            KeyCode::Char('u') if ctrl => self.page(-1),
            KeyCode::PageDown => self.page(1),
            KeyCode::PageUp => self.page(-1),
            KeyCode::Char('/') => self.mode = Mode::Filter,
            KeyCode::Char(' ') => self.mode = Mode::Action,
            KeyCode::Char('?') => self.mode = Mode::Help,
            KeyCode::Char('i') if self.view == View::Board => {
                self.show_idle = !self.show_idle;
                let hidden = self.snapshot.as_ref().map_or(0, |s| {
                    s.topics
                        .iter()
                        .filter(|t| self.group(t) == Group::Idle)
                        .count()
                });
                self.toast(
                    Level::Info,
                    if self.show_idle {
                        format!("Showing {hidden} idle workspaces")
                    } else {
                        "Hiding idle workspaces".into()
                    },
                );
            }
            KeyCode::Char('f') if self.view == View::Runs => {
                self.log.scroll = 0;
                self.toast(Level::Info, "Following the log");
            }
            KeyCode::Char('r') => {
                if let Some(feed) = &self.feed {
                    feed.refresh();
                }
                self.toast(Level::Info, "Reading the graph again");
            }
            KeyCode::Char('y') => self.yank(false),
            KeyCode::Char('Y') => self.yank(true),
            KeyCode::Enter => match self.view {
                View::Board => {
                    let run = self
                        .selected_topic()
                        .and_then(|t| self.latest_run(t))
                        .map(|r| r.id.clone());
                    match run {
                        Some(id) => {
                            self.run_id = Some(id);
                            self.set_view(View::Runs);
                        }
                        None => {
                            self.toast(Level::Info, "No ci runs for this topic yet; ␣ starts one")
                        }
                    }
                }
                View::Runs => self.zoom = !self.zoom,
                View::Trunk => {}
            },
            _ => {}
        }
    }

    fn page(&mut self, direction: isize) {
        if self.view == View::Runs {
            self.scroll_log(-direction * 20);
        } else {
            self.move_selection(direction * 8);
        }
    }

    fn yank(&mut self, path: bool) {
        let text = match self.view {
            View::Board => self.selected_topic().and_then(|t| {
                if path {
                    t.root.as_ref().map(|r| r.display().to_string())
                } else {
                    Some(t.head.change_id.chars().take(12).collect())
                }
            }),
            View::Runs => self.selected_run().map(|r| {
                if path {
                    r.log.display().to_string()
                } else {
                    r.id.clone()
                }
            }),
            View::Trunk => self
                .snapshot
                .as_ref()
                .and_then(|s| s.trunk.get(self.trunk_index))
                .map(|c| c.commit_id.chars().take(12).collect()),
        };
        match text {
            Some(text) => {
                crate::osc52(&text);
                self.toast(Level::Ok, format!("Copied {text}"));
            }
            None => self.toast(Level::Warn, "Nothing to copy here"),
        }
    }

    /// The workspace an action applies to in the current view.
    fn target(&self) -> Option<Target> {
        let topic = match self.view {
            View::Runs => {
                let run = self.selected_run()?;
                self.snapshot
                    .as_ref()?
                    .topics
                    .iter()
                    .find(|t| t.root.as_ref() == Some(&run.workspace))?
            }
            _ => self.selected_topic()?,
        };
        Some(Target {
            workspace: topic.workspace.clone()?,
            root: topic.root.clone()?,
            topic: format!(
                "{} \"{}\"",
                topic.head.short,
                if topic.head.title.is_empty() {
                    "(no description)"
                } else {
                    &topic.head.title
                }
            ),
            owner: topic.owner.clone(),
        })
    }

    pub fn request(&mut self, action: Action) {
        let target = self.target();
        if action.needs_workspace() && target.is_none() {
            self.toast(Level::Warn, "That needs a topic checked out in a workspace");
            return;
        }
        let run = if action == Action::StopRun {
            match self.selected_run().filter(|r| r.state == RunState::Running) {
                Some(run) => Some(run.id.clone()),
                None => {
                    self.toast(
                        Level::Warn,
                        "Select a running run in the Runs view to stop it",
                    );
                    return;
                }
            }
        } else {
            None
        };
        let mut warnings = vec![];
        if let Some(target) = &target {
            if action.mutating() && target.owner == "active" {
                warnings
                    .push("An active Codex task owns this workspace; it may be mid-edit.".into());
            }
            if action.mutating() {
                if let Some(busy) = jobs::busy(&self.runs, &target.root) {
                    self.toast(
                        Level::Warn,
                        format!(
                            "{busy} is still changing {}; wait for it or stop it",
                            target.workspace
                        ),
                    );
                    return;
                }
            }
        }
        let pending = Pending {
            action,
            target,
            run,
            warnings,
        };
        if action.confirms() || !pending.warnings.is_empty() {
            self.mode = Mode::Confirm(pending);
        } else {
            self.perform(&pending);
        }
    }

    fn perform(&mut self, pending: &Pending) {
        let action = pending.action;
        match (action, &pending.target) {
            (Action::StopRun, _) => {
                let run = self
                    .runs
                    .iter()
                    .find(|r| Some(&r.id) == pending.run.as_ref())
                    .cloned();
                match run.map(|run| jobs::stop(&run)) {
                    Some(Ok(())) => self.toast(
                        Level::Ok,
                        "Sent SIGTERM; ci checkpoints before history surgery",
                    ),
                    Some(Err(error)) => {
                        self.toast(Level::Error, format!("Could not stop it: {error}"))
                    }
                    None => self.toast(Level::Warn, "That run is gone"),
                }
            }
            (Action::RefreshCi, Some(target)) => {
                let started = jobs::detach(
                    Command::new("context-status")
                        .arg("refresh")
                        .arg(&target.root),
                );
                if started {
                    self.toast(
                        Level::Info,
                        format!("Asking the forges about {}…", target.workspace),
                    );
                } else {
                    self.toast(Level::Error, "context-status is not on PATH");
                }
            }
            (Action::Dashboard, Some(target)) => {
                if jobs::detach(Command::new("jj-dashboard").arg(&target.root)) {
                    self.toast(Level::Info, format!("Opening jjui in {}", target.workspace));
                } else {
                    self.toast(Level::Error, "jj-dashboard is not on PATH");
                }
            }
            (_, Some(target)) => {
                let Some(args) = action.args() else { return };
                match jobs::launch(&self.ci, &args, &target.root, action.mutating()) {
                    Ok(id) => {
                        self.toast(
                            Level::Ok,
                            format!("Started ci {} in {}", args.join(" "), target.workspace),
                        );
                        self.run_id = Some(id);
                        self.set_view(View::Runs);
                        self.log.scroll = 0;
                    }
                    Err(error) => self.toast(Level::Error, error),
                }
            }
            (_, None) => {}
        }
    }

    pub fn tick(&mut self) {
        self.frame = self.frame.wrapping_add(1);
        if self
            .toast
            .as_ref()
            .is_some_and(|t| Instant::now() > t.until)
        {
            self.toast = None;
        }
    }
}
