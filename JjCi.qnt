// A finite protocol model for the lifecycle enforced by ci.nu.
//
// The model abstracts command execution and remote failures. It tracks only
// the safety-relevant facts: workspace ownership, topic readiness, exact
// published head, conflict state, the head a landing gate passed, the stack
// parent, and the trunk tip. Validation is tagged with the head it checked
// and the head captured at publication, so later edits cannot blur that
// relationship. Publication also records that the topic was based on the
// current trunk.
//
// Landing is a fast-forward of main to the exact head a gate (the flake
// checks built locally by default, GitHub Actions, or nixbot)
// passed, pushed with a lease on the trunk the topic is based on. No forge
// merges: a squash, rebase, or merge commit would put a commit on main that
// no gate ran on.
//
// Landings share one runway: a topic lands only while it holds the runway,
// and every other topic lands from the same runway, so trunk never moves
// while a topic holds it. A topic that rebases there keeps the clearance it
// then takes. `ci land` takes the runway only when it is clear, with no
// landing in flight and no topic held ahead; otherwise it refuses. `ci queue`
// holds the topic's exact head instead, and the drainer takes the runway for
// each held topic in turn, only for the head that was held or a clean rebase
// of it. A topic stacked on an unlanded parent may be held: the drainer
// orders it behind its parent, and it still lands only once that parent has
// landed. A train that fails on another topic may put this one back in line
// as it leaves the runway. The model leaves
// out what moves trunk from outside the runway, such as another machine,
// which `ci land --attempts` retries. A train (`ci land --train`, or the
// drainer with several held topics) lands several topics in one fast-forward
// from the same runway; this model follows one topic and leaves trains out.
//
// agent/machine.mjs refines this protocol into the single-topic command
// states. Its Nushell host executes Publish via publish-topic, Hold via
// hold-topic, TakeRunway via with-runway, GatePasses via wait-for-pipeline,
// and Land via advance-main. Only a failed Land lease retries; each
// rewritten head goes through Publish and GatePasses again. These guards
// remain in the effect implementations as well as in the agent.
module JjCi {
  // Topic heads and trunk heads are disjoint, so a topic head on main is
  // always a landed topic.
  pure val Heads: Set[str] = Set("h0", "h1")
  pure val MainHeads: Set[str] = Set("m0", "m1")

  // passedHead, parentLanded, mainHead, and othersAhead are facts owned by
  // the outside world: the gate's verdicts, the stack parent, other topics
  // landing on trunk, and other topics on the runway or held ahead of this
  // one.
  type State = {
    owner: bool,
    active: bool,
    head: str,
    base: str,
    conflict: bool,
    validated: bool,
    validatedHead: str,
    published: bool,
    publishedHead: str,
    publishedValidated: bool,
    publishedValidationHead: str,
    publishedConflictFree: bool,
    publishedFresh: bool,
    passedHead: str,
    parentLanded: bool,
    mainHead: str,
    landedOnto: str,
    delivered: bool,
    workspaceBase: str,
    onRunway: bool,
    holding: bool,
    heldHead: str,
    othersAhead: bool
  }

  var s: State

  action init = {
    nondet h = Heads.oneOf()
    nondet b = MainHeads.oneOf()
    // false for a topic stacked on an unlanded parent.
    nondet parent = Set(true, false).oneOf()
    s' = {
      owner: true,
      active: true,
      head: h,
      base: b,
      conflict: false,
      validated: false,
      validatedHead: "none",
      published: false,
      publishedHead: "none",
      publishedValidated: false,
      publishedValidationHead: "none",
      publishedConflictFree: false,
      publishedFresh: false,
      passedHead: "none",
      parentLanded: parent,
      mainHead: b,
      landedOnto: "none",
      delivered: false,
      workspaceBase: "topic",
      onRunway: false,
      holding: false,
      heldHead: "none",
      othersAhead: false
    }
  }

  action Edit = {
    nondet h = Heads.oneOf()
    all {
      s.owner,
      s.active,
      not(s.delivered),
      s' = { head: h, validated: false, validatedHead: "none", ...s }
    }
  }

  // A rebase onto the current trunk rewrites every commit in the topic, so
  // the head changes too. A clean rebase leaves the change's own diff alone,
  // so a hold follows it to the new head: the drainer lands a held topic that
  // a train put back on main, or that moved with its stack parent, at its
  // rebased head.
  action RebaseClean = {
    nondet h = Heads.oneOf()
    all {
      s.owner,
      s.active,
      not(s.conflict),
      not(s.delivered),
      s' = {
        base: s.mainHead,
        head: h,
        validated: false,
        validatedHead: "none",
        heldHead: if (s.holding) h else s.heldHead,
        ...s
      }
    }
  }

  action RebaseConflicted = {
    nondet h = Heads.oneOf()
    all {
      s.owner,
      s.active,
      not(s.conflict),
      not(s.delivered),
      s' = {
        base: s.mainHead,
        head: h,
        conflict: true,
        validated: false,
        validatedHead: "none",
        ...s
      }
    }
  }

  action Resolve = {
    all {
      s.owner,
      s.active,
      s.conflict,
      not(s.delivered),
      s' = { conflict: false, validated: false, validatedHead: "none", ...s }
    }
  }

  action Validate = {
    all {
      s.owner,
      s.active,
      not(s.conflict),
      not(s.delivered),
      s' = { validated: true, validatedHead: s.head, ...s }
    }
  }

  action Publish = {
    all {
      s.owner,
      s.active,
      s.validated,
      s.validatedHead == s.head,
      not(s.conflict),
      not(s.delivered),
      s.base == s.mainHead,
      s' = {
        publishedFresh: s.base == s.mainHead,
        published: true,
        publishedHead: s.head,
        publishedValidated: s.validated,
        publishedValidationHead: s.validatedHead,
        publishedConflictFree: not(s.conflict),
        ...s
      }
    }
  }

  // The gate checks an exact published head (CI on every push, the local
  // gate when `ci land` runs) and passes it by commit, so a verdict never
  // carries over to a rewritten head. A failing run simply never passes.
  action GatePasses = {
    all {
      s.published,
      s' = { passedHead: s.publishedHead, ...s }
    }
  }

  // The stack parent lands; the child is then based on trunk.
  action ParentLands = {
    all {
      not(s.parentLanded),
      s' = { parentLanded: true, ...s }
    }
  }

  // Another topic lands first and moves trunk. It lands from the runway, so
  // not while this topic holds it.
  action TrunkAdvances = {
    nondet m = MainHeads.oneOf()
    all {
      not(s.delivered),
      not(s.onRunway),
      m != s.mainHead,
      s' = { mainHead: m, ...s }
    }
  }

  // Another topic takes the runway or is held, ahead of this one. Topics
  // that arrive while this one is held or on the runway line up behind it.
  action OthersArrive = {
    all {
      not(s.delivered),
      not(s.onRunway),
      not(s.holding),
      not(s.othersAhead),
      s' = { othersAhead: true, ...s }
    }
  }

  // The topics ahead of this one land or drop out.
  action OthersLeave = {
    all {
      s.othersAhead,
      s' = { othersAhead: false, ...s }
    }
  }

  // `ci queue` holds the topic's exact published head for the drainer, which
  // lands held topics in the order they were held.
  action Hold = {
    all {
      s.owner,
      s.active,
      s.published,
      s.publishedHead == s.head,
      not(s.delivered),
      not(s.holding),
      not(s.onRunway),
      s' = { holding: true, heldHead: s.head, ...s }
    }
  }

  // A hold ends without the topic taking the runway: its head changed since
  // it was held, or its owner dropped it.
  action DropHold = {
    all {
      s.holding,
      s' = { holding: false, heldHead: "none", ...s }
    }
  }

  // The topic takes the runway once no landing is in flight and no topic is
  // held ahead of it: `ci land` from its owner, which refuses rather than
  // wait, or the drainer from the topic's hold, only for the head held.
  action TakeRunway = {
    all {
      s.published,
      not(s.delivered),
      not(s.onRunway),
      not(s.othersAhead),
      if (s.holding) s.head == s.heldHead else s.owner and s.active,
      s' = { onRunway: true, holding: false, heldHead: "none", ...s }
    }
  }

  // A landing that stops short, on a conflict or a failed gate, leaves the
  // runway without landing. A drainer's train whose clearance another topic
  // failed puts this one back in line instead: held again at its head, in
  // the place it held before.
  action LeaveRunway = {
    nondet requeue = Set(true, false).oneOf()
    all {
      s.onRunway,
      not(s.delivered),
      s' = {
        onRunway: false,
        holding: requeue,
        heldHead: if (requeue) s.head else "none",
        ...s
      }
    }
  }

  // The topic fast-forwards main to the exact head the gate passed, from the
  // runway, which it then leaves. The push carries a lease on the trunk the
  // topic is based on, so it fails if trunk moved, and the topic must rebase,
  // republish, and pass again.
  action Land = {
    all {
      s.owner,
      s.active,
      s.published,
      not(s.conflict),
      not(s.delivered),
      s.onRunway,
      s.parentLanded,
      s.publishedHead == s.head,
      s.passedHead == s.head,
      s.base == s.mainHead,
      s' = {
        landedOnto: s.mainHead,
        mainHead: s.head,
        delivered: true,
        onRunway: false,
        ...s
      }
    }
  }

  // Releasing a topic leaves its workspace on main (one that `ci start` did
  // not create) or drops it (one `ci start` made for this topic), so no
  // workspace outlives its owner.
  action Finish = {
    nondet base = Set("main", "dropped").oneOf()
    all {
      s.owner,
      s.active,
      not(s.conflict),
      s.delivered or not(s.published),
      s' = { owner: false, active: false, workspaceBase: base, ...s }
    }
  }

  // Abandoning discards unpublished work, conflicts included. The model
  // omits PR closure, so a published topic cannot be abandoned.
  action Abandon = {
    nondet base = Set("main", "dropped").oneOf()
    all {
      s.owner,
      s.active,
      not(s.published),
      s' = {
        owner: false,
        active: false,
        conflict: false,
        workspaceBase: base,
        ...s
      }
    }
  }

  // The explicit stutter matches TLA+'s [Next]_vars and keeps TLC from
  // reporting finished topics as deadlocks.
  action step = any {
    Edit,
    RebaseClean,
    RebaseConflicted,
    Resolve,
    Validate,
    Publish,
    GatePasses,
    ParentLands,
    TrunkAdvances,
    OthersArrive,
    OthersLeave,
    Hold,
    DropHold,
    TakeRunway,
    LeaveRunway,
    Land,
    Finish,
    Abandon,
    s' = s
  }

  val TypeOK = and {
    s.owner.in(Set(true, false)),
    s.active.in(Set(true, false)),
    s.head.in(Heads),
    s.base.in(MainHeads),
    s.conflict.in(Set(true, false)),
    s.validated.in(Set(true, false)),
    s.validatedHead.in(Set("h0", "h1", "none")),
    s.published.in(Set(true, false)),
    s.publishedHead.in(Set("h0", "h1", "none")),
    s.publishedValidated.in(Set(true, false)),
    s.publishedValidationHead.in(Set("h0", "h1", "none")),
    s.publishedConflictFree.in(Set(true, false)),
    s.publishedFresh.in(Set(true, false)),
    s.passedHead.in(Set("h0", "h1", "none")),
    s.parentLanded.in(Set(true, false)),
    s.mainHead.in(Set("m0", "m1", "h0", "h1")),
    s.landedOnto.in(Set("m0", "m1", "none")),
    s.delivered.in(Set(true, false)),
    s.workspaceBase.in(Set("topic", "main", "dropped")),
    s.onRunway.in(Set(true, false)),
    s.holding.in(Set(true, false)),
    s.heldHead.in(Set("h0", "h1", "none")),
    s.othersAhead.in(Set(true, false))
  }

  val NoPublishWhileUnsafe =
    not(s.published) or
      (s.publishedHead.in(Heads) and s.publishedValidated and s.publishedConflictFree)

  val PublishedFromFreshBase = not(s.published) or s.publishedFresh

  val PublishedHeadWasValidated =
    not(s.published) or s.publishedHead == s.publishedValidationHead

  val NoFinishWithConflict = s.owner or not(s.conflict)

  val FinishLeavesMain =
    s.active or s.workspaceBase.in(Set("main", "dropped"))

  // A workspace is freed only by its released owner, with nothing in flight.
  val NoDropWhilePending =
    s.workspaceBase != "dropped" or
      (not(s.owner) and (s.delivered or not(s.published)))

  // Not rocket science: main only ever holds a topic commit a gate passed.
  val MainOnlyHoldsPassedHeads =
    not(s.mainHead.in(Heads)) or s.mainHead == s.passedHead

  // Delivery is the published commit itself, not a forge-made copy of it, so
  // change IDs, the impact declared for them, and ancestry checks survive
  // landing.
  val DeliveryIsPublishedHead = not(s.delivered) or s.mainHead == s.publishedHead

  // An edit or rebase after landing keeps the topic undelivered.
  val DeliveredHeadIsLocal = not(s.delivered) or s.mainHead == s.head

  // A stacked topic lands only after its parent.
  val LandsAfterParent = not(s.delivered) or s.parentLanded

  // Landing fast-forwards from the trunk the topic was based on: main moved
  // from the topic's own base, never from a trunk the gate did not test.
  val LandingIsFastForward = not(s.delivered) or s.landedOnto == s.base

  // Only a published topic that its owner is still landing holds the runway.
  val RunwayOnlyWhileLanding =
    not(s.onRunway) or (s.owner and s.active and s.published and not(s.delivered))

  // A held topic is published, undelivered, and not yet on the runway, and
  // its hold names one exact head.
  val HeldOnlyWhileWaiting =
    not(s.holding) or
      (s.owner and s.published and not(s.delivered) and not(s.onRunway) and s.heldHead.in(Heads))

  // While a topic holds the runway, trunk stays put, so a topic that rebased
  // there stays on trunk, and the clearance it takes is never thrown away:
  // no landing restarts because another one landed. orKeep(s) makes these
  // [A]_vars action properties, the only form of action under [] that TLC
  // accepts.
  temporal RunwayTopicStaysOnTrunk =
    always((
      (s.onRunway and next(s.onRunway) and s.base == s.mainHead) implies
        next(s.base) == next(s.mainHead)
    ).orKeep(s))

  // A topic lands only from the runway.
  temporal LandsFromRunway =
    always(((not(s.delivered) and next(s.delivered)) implies s.onRunway).orKeep(s))

  // Nothing takes the runway ahead of its turn: not while another landing is
  // in flight or another topic is held ahead.
  temporal RunwayTakenInTurn =
    always(((not(s.onRunway) and next(s.onRunway)) implies not(s.othersAhead)).orKeep(s))

  // The drainer lands only the head that was held: a topic edited since it
  // was held loses its hold instead of taking the runway.
  temporal HoldLandsHeldHead =
    always(((s.holding and next(s.onRunway)) implies s.head == s.heldHead).orKeep(s))
}
