// A bounded abstraction of the supplied “Release loop” diagram.
//
// The model follows its control flow: commits on main enter a gate; green
// dispatches TestFlight; red gates and failed builds reach a fixer; a landed
// fix moves main and re-enters the gate; timeouts and stalled infrastructure
// pause for a person; a released build can be manually promoted and verified.
//
// This is a comparison model, not an implementation of schlich/ci. The
// picture leaves build artifact identity, retry policy, and fairness open.
module ReleaseLoop {
  pure val Commits: Set[str] = Set("c0", "c1", "c2")

  pure val Waiting = "waiting"
  pure val Gate = "gate"
  pure val TestFlight = "testflight"
  pure val Fixer = "fixer"
  pure val LandFix = "land_fix"
  pure val Person = "person"
  pure val Production = "production"
  pure val Phases = Set(Waiting, Gate, TestFlight, Fixer, LandFix, Person, Production)

  pure val NoCommit = "none"
  pure val NoAttention = "none"

  type State = {
    phase: str,
    mainHead: str,
    candidate: str,
    fixerHead: str,
    gatePassed: Set[str],
    releasedHead: str,
    productionHead: str,
    verifiedHead: str,
    attention: str
  }

  var s: State

  action init = {
    nondet c = Commits.oneOf()
    s' = {
      phase: Waiting,
      mainHead: c,
      candidate: c,
      fixerHead: NoCommit,
      gatePassed: Set(),
      releasedHead: NoCommit,
      productionHead: NoCommit,
      verifiedHead: NoCommit,
      attention: NoAttention
    }
  }

  action NewCommit = {
    nondet c = Commits.oneOf()
    all {
      s.phase == Waiting,
      c != s.mainHead,
      s' = {
        phase: Gate,
        mainHead: c,
        candidate: c,
        fixerHead: NoCommit,
        attention: NoAttention,
        ...s
      }
    }
  }

  action GateGreen = {
    all {
      s.phase == Gate,
      s.candidate == s.mainHead,
      s' = {
        phase: TestFlight,
        gatePassed: s.gatePassed.union(Set(s.candidate)),
        ...s
      }
    }
  }

  action GateRed = {
    all {
      s.phase == Gate,
      s' = { phase: Fixer, ...s }
    }
  }

  action GateTimeout = {
    all {
      s.phase == Gate,
      s' = { phase: Person, attention: "gate_timeout", ...s }
    }
  }

  action BuildPass = {
    all {
      s.phase == TestFlight,
      s.candidate.in(s.gatePassed),
      s' = { phase: Waiting, releasedHead: s.candidate, ...s }
    }
  }

  action BuildFail = {
    all {
      s.phase == TestFlight,
      s' = { phase: Fixer, ...s }
    }
  }

  action InfraFailure = {
    all {
      s.phase == TestFlight,
      s' = { phase: Person, attention: "infra_or_stalled", ...s }
    }
  }

  action FixerOpensPR = {
    nondet c = Commits.oneOf()
    all {
      s.phase == Fixer,
      s' = { phase: LandFix, fixerHead: c, ...s }
    }
  }

  // Models the land-fix CI/runner gate passing and the merge moving main.
  // The new main head then goes through the regular gate.
  action LandFixPassAndMerge = {
    all {
      s.phase == LandFix,
      s.fixerHead.in(Commits),
      s' = {
        phase: Gate,
        mainHead: s.fixerHead,
        candidate: s.fixerHead,
        fixerHead: NoCommit,
        attention: NoAttention,
        ...s
      }
    }
  }

  action LandFixNeedsPerson = {
    all {
      s.phase == LandFix,
      s' = { phase: Person, attention: "review_or_red", ...s }
    }
  }

  action ClearAttention = {
    all {
      s.phase == Person,
      s' = {
        phase: Waiting,
        candidate: s.mainHead,
        fixerHead: NoCommit,
        attention: NoAttention,
        ...s
      }
    }
  }

  action ManualPromote = {
    all {
      s.phase == Waiting,
      s.releasedHead != NoCommit,
      s.productionHead == NoCommit or s.verifiedHead == s.productionHead,
      s' = {
        phase: Production,
        productionHead: s.releasedHead,
        ...s
      }
    }
  }

  action VerifyProduction = {
    all {
      s.phase == Production,
      s.productionHead != NoCommit,
      s' = {
        phase: Waiting,
        verifiedHead: s.productionHead,
        ...s
      }
    }
  }

  action step = any {
    NewCommit,
    GateGreen,
    GateRed,
    GateTimeout,
    BuildPass,
    BuildFail,
    InfraFailure,
    FixerOpensPR,
    LandFixPassAndMerge,
    LandFixNeedsPerson,
    ClearAttention,
    ManualPromote,
    VerifyProduction,
    s' = s
  }

  val GateSetType =
    s.gatePassed == Set() or
      s.gatePassed == Set("c0") or
      s.gatePassed == Set("c1") or
      s.gatePassed == Set("c2") or
      s.gatePassed == Set("c0", "c1") or
      s.gatePassed == Set("c0", "c2") or
      s.gatePassed == Set("c1", "c2") or
      s.gatePassed == Set("c0", "c1", "c2")

  val TypeOK = and {
    s.phase.in(Phases),
    s.mainHead.in(Commits),
    s.candidate.in(Commits),
    s.fixerHead == NoCommit or s.fixerHead.in(Commits),
    GateSetType,
    s.releasedHead == NoCommit or s.releasedHead.in(Commits),
    s.productionHead == NoCommit or s.productionHead.in(Commits),
    s.verifiedHead == NoCommit or s.verifiedHead.in(Commits),
    s.attention.in(Set(NoAttention, "gate_timeout", "infra_or_stalled", "review_or_red"))
  }

  // Every released head was cleared by the gate.
  val ReleaseWasGated =
    s.releasedHead == NoCommit or s.releasedHead.in(s.gatePassed)

  // Promotion and verification refer only to a gate-cleared release.
  val ProductionWasGated =
    s.productionHead == NoCommit or s.productionHead.in(s.gatePassed)
  val VerificationWasGated =
    s.verifiedHead == NoCommit or s.verifiedHead.in(s.gatePassed)

  // The normal gate checks the current main head in this abstraction.
  val GateChecksCurrentMain =
    s.phase != Gate or s.candidate == s.mainHead

  // A person pause has a reason and cannot leave without clearing attention.
  val PersonPauseIsExplicit =
    s.phase != Person or s.attention != NoAttention
}
