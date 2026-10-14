//! The ci log: the OTLP/JSON log records `ci.nu` appends to
//! `$XDG_STATE_HOME/ci/log.otlp.jsonl` (or `$CI_LOG`), one
//! `ExportLogsServiceRequest` per line. The tower reads only the impact
//! declarations from it. Keep in step with `read-ci-log` and
//! `impact-declarations` in ci.nu.

use std::collections::HashMap;
use std::path::PathBuf;

use serde_json::Value;

use crate::jobs;

const IMPACT_EVENT: &str = "ci.impact.set";

pub fn path() -> PathBuf {
    match std::env::var_os("CI_LOG").filter(|path| !path.is_empty()) {
        Some(path) => PathBuf::from(path),
        None => jobs::state_home().join("ci").join("log.otlp.jsonl"),
    }
}

/// Each change's latest declared impact class, by full change ID.
pub fn impact_declarations() -> HashMap<String, String> {
    std::fs::read_to_string(path())
        .map(|text| parse_impact_declarations(&text))
        .unwrap_or_default()
}

/// Only lines naming the event are decoded, so the board stays fast however
/// long the log grows.
fn parse_impact_declarations(text: &str) -> HashMap<String, String> {
    let needle = format!("\"eventName\":\"{IMPACT_EVENT}\"");
    let mut declarations = HashMap::new();
    for line in text.lines().filter(|line| line.contains(&needle)) {
        let Ok(request) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        for record in log_records(&request) {
            if record["eventName"] != IMPACT_EVENT {
                continue;
            }
            if let (Some(change), Some(impact)) = (
                string_attribute(record, "ci.change_id"),
                string_attribute(record, "ci.impact"),
            ) {
                declarations.insert(change, impact);
            }
        }
    }
    declarations
}

fn log_records(request: &Value) -> impl Iterator<Item = &Value> {
    request["resourceLogs"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|resource| resource["scopeLogs"].as_array().into_iter().flatten())
        .flat_map(|scope| scope["logRecords"].as_array().into_iter().flatten())
}

fn string_attribute(record: &Value, key: &str) -> Option<String> {
    record["attributes"]
        .as_array()?
        .iter()
        .find(|attribute| attribute["key"] == key)?["value"]["stringValue"]
        .as_str()
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(event: &str, change: &str, impact: &str) -> String {
        format!(
            r#"{{"resourceLogs":[{{"resource":{{"attributes":[]}},"scopeLogs":[{{"scope":{{"name":"ci"}},"logRecords":[{{"timeUnixNano":"1","eventName":"{event}","body":{{"stringValue":""}},"attributes":[{{"key":"ci.change_id","value":{{"stringValue":"{change}"}}}},{{"key":"ci.impact","value":{{"stringValue":"{impact}"}}}}]}}]}}]}}]}}"#
        )
    }

    #[test]
    fn latest_declaration_wins_and_other_events_are_ignored() {
        let text = [
            line(IMPACT_EVENT, "kxyz", "refactor"),
            line("ci.status", "kxyz", "breaking"),
            line(IMPACT_EVENT, "qrst", "behavior"),
            "{\"eventName\":\"ci.impact.set\" truncated".into(),
            line(IMPACT_EVENT, "kxyz", "breaking"),
        ]
        .join("\n");
        let declarations = parse_impact_declarations(&text);
        assert_eq!(
            declarations.get("kxyz").map(String::as_str),
            Some("breaking")
        );
        assert_eq!(
            declarations.get("qrst").map(String::as_str),
            Some("behavior")
        );
        assert_eq!(declarations.len(), 2);
    }
}
