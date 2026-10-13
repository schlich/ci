//! `jj-ci-lifecycle classify` reads a topic observation as JSON on stdin and
//! prints its stage, next step, and the protocol steps the lifecycle allows.

use std::io::Read;
use std::process::ExitCode;

use jj_ci_lifecycle::stage::Observation;

fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref() {
        Some("classify") => {}
        _ => {
            eprintln!("usage: jj-ci-lifecycle classify < observation.json");
            return ExitCode::from(2);
        }
    }
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
