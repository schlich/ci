//! `jj-ci-lifecycle classify` reads a topic observation as JSON on stdin and
//! prints its stage, next step, and the protocol steps the lifecycle allows.
//! `jj-ci-lifecycle diagram [STATE]` prints the lifecycle as a Mermaid state
//! diagram, with STATE (a `machine_state` from `classify`) highlighted.

use std::io::Read;
use std::process::ExitCode;

use jj_ci_lifecycle::diagram::{mermaid, Node};
use jj_ci_lifecycle::stage::Observation;

const USAGE: &str =
    "usage: jj-ci-lifecycle classify < observation.json\n       jj-ci-lifecycle diagram [STATE]";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("classify") => classify(),
        Some("diagram") => diagram(args.get(1).map(String::as_str)),
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn diagram(current: Option<&str>) -> ExitCode {
    let node = match current.map(|name| (name, Node::parse(name))) {
        None => None,
        Some((_, Some(node))) => Some(node),
        Some((name, None)) => {
            let known: Vec<_> = Node::ALL.iter().map(|node| node.name()).collect();
            eprintln!(
                "jj-ci-lifecycle: unknown state {name:?}; expected one of {}",
                known.join(", ")
            );
            return ExitCode::from(2);
        }
    };
    print!("{}", mermaid(node));
    ExitCode::SUCCESS
}

fn classify() -> ExitCode {
    let mut input = String::new();
    if let Err(error) = std::io::stdin().read_to_string(&mut input) {
        eprintln!("jj-ci-lifecycle: reading stdin: {error}");
        return ExitCode::FAILURE;
    }
    let observation: Observation = match serde_json::from_str(&input) {
        Ok(observation) => observation,
        Err(error) => {
            eprintln!("jj-ci-lifecycle: invalid observation: {error}");
            return ExitCode::FAILURE;
        }
    };
    println!(
        "{}",
        serde_json::to_string(&observation.classify()).expect("a classification serializes")
    );
    ExitCode::SUCCESS
}
