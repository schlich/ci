# Release-loop model comparison

This compares the supplied “Release loop” diagram with the topic lifecycle in
[JjCi.qnt](../JjCi.qnt). [ReleaseLoop.qnt](../ReleaseLoop.qnt) is a bounded
Quint abstraction of the diagram. It is a comparison model, not part of the
ci command implementation.

## Screenshot flow

1. A new commit on main enters the gate.
2. A green gate dispatches an internal TestFlight build; a red gate sends work
   to a fixer.
3. A passing build records a release and returns to waiting. A failed build
   sends work to the fixer.
4. The fixer opens a PR. If the land-fix CI/runner gate passes, merging moves
   main and sends the new head through the regular gate. Review-needed or red
   land fixes pause for a person.
5. Gate timeouts and stalled/infrastructure failures also pause for a person.
   Clearing attention returns to waiting.
6. A person manually promotes a released head to production; verification
   returns the loop to waiting.

The picture does not specify artifact identity, retry limits, or fairness. The
Quint abstraction does not invent those policies.

## Transition mapping

| Screenshot concept | ReleaseLoop.qnt | Closest JjCi.qnt concept | Difference |
|---|---|---|---|
| Waiting for commits | Waiting, NewCommit | init, then topic actions | The screenshot reacts to commits already on main; ci starts from a task-owned JJ topic. |
| Gate | GateGreen, GateRed, GateTimeout | Validate, Publish, GatePasses | ci separates preflight, publication, and clearance; its clearance names the exact published head. |
| TestFlight build | TestFlight, BuildPass, BuildFail, InfraFailure | No direct JjCi.qnt counterpart | ci clears checks before landing. Activation and ci verify are later operational steps outside this topic protocol model. |
| Fixer opens PR | Fixer, FixerOpensPR | No automatic repair action | ci stops on conflicts or failed checks. Workspace ownership supports agent work, but JjCi.qnt does not spawn a fixer or open a PR. |
| Land fix / main moves | LandFixPassAndMerge | Land, TrunkAdvances | The screenshot merges a fix and gates the moved main again. ci lands the exact cleared topic head by fast-forward and serializes landings through a queue. |
| Needs a person | Person, ClearAttention | No person-pause state | ci stops on failures; the operator decides what to do outside the modeled lifecycle. |
| Production promotion / verified | ManualPromote, VerifyProduction | No direct counterpart | The screenshot models promotion in its loop. ci separates landing from later activation and verification. |

## Shared safety questions

| Question | ReleaseLoop.qnt | JjCi.qnt |
|---|---|---|
| Can unchecked work be released or landed? | ReleaseWasGated, ProductionWasGated | PublishedHeadWasValidated, MainOnlyHoldsPassedHeads, DeliveryIsPublishedHead |
| Does the normal gate test the current candidate? | GateChecksCurrentMain | Exact validation/publication head matching, plus the topic's base must still equal the current trunk at landing |
| What happens when another change moves main? | Not modeled | TrunkAdvances plus the queue and landing-base guard; operationally, a lost lease causes rebase, republish, and clearance again |
| Can a failure recover automatically? | Repair and person paths are explicit; retries are unspecified | Conflicts and failed checks stop; only a lost landing race retries operationally, within the configured attempt limit |
| Is human intervention represented? | Yes, as a paused Person state | No; starting ci land, activating a release, and verifying it are operator actions outside this model |

## What the comparison shows

The models protect different boundaries. The screenshot automates a **release
and repair loop** around commits already on main. ci controls **how a JJ
topic becomes main**, including exact-head clearance and serialized
fast-forward landing.

Their clearest shared safety question is whether the exact commit cleared by a
gate is the one released or delivered. JjCi.qnt encodes validation,
publication, clearance, and landing head identity, and requires the topic to
remain based on current main. ReleaseLoop.qnt records gate-cleared heads
and requires the released and promoted heads to have passed the gate. It does
not identify a concrete build artifact or model concurrent main updates.

The Nix ci-model check verifies both Quint models. The release-loop model
checks safety invariants only; it makes no liveness claim because the diagram
does not define scheduling or fairness.

