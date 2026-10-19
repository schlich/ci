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
// Landings go through one queue: a topic lands only from its front, and
// every other topic lands through the same queue, so trunk never moves while
// a topic holds the front. A topic that rebases there keeps the clearance it
// then takes. The model leaves out what moves trunk from outside the queue,
// such as another machine, which `ci land --attempts` retries. A train
// (`ci land --train`) lands several topics in one fast-forward from the front
// of the same queue; this model follows one topic and leaves trains out.
//
// agent/machine.mjs refines this protocol into the single-topic command
// states. Its Nushell host executes Publish via publish-topic, Queue via
// with-landing-queue, GatePasses via wait-for-pipeline, and Land via
// advance-main. Only a failed Land lease retries; each rewritten head goes
// through Publish and GatePasses again. These guards remain in the effect
// implementations as well as in the agent.
module JjCi {
  // Topic heads and trunk heads are disjoint, so a topic head on main is
  // always a landed topic.
  pure val Heads: Set[str] = Set("h0", "h1")
  pure val MainHeads: Set[str] = Set("m0", "m1")

  // passedHead, parentLanded, and mainHead are facts owned by the outside
  // world: the gate's verdicts, the stack parent, and other topics landing
  // on trunk.
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
    queued: bool
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
      queued: false
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
  // the head changes too.
  action RebaseClean = {
    nondet h = Heads.oneOf()
    all {
      s.owner,
      s.active,
      not(s.conflict),
      not(s.delivered),
      s' = { base: s.mainHead, head: h, validated: false, validatedHead: "none", ...s }
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

  // Another topic lands first and moves trunk. It lands from the front of
  // the landing queue, so not while this topic holds the front.
  action TrunkAdvances = {
    nondet m = MainHeads.oneOf()
    all {
      not(s.delivered),
      not(s.queued),
      m != s.mainHead,
      s' = { mainHead: m, ...s }
    }
  }

  // `ci land` reaches the front of the landing queue, once the topic is
  // published and its fast checks have passed.
  action Queue = {
    all {
      s.owner,
      s.active,
      s.published,
      not(s.delivered),
      not(s.queued),
      s' = { queued: true, ...s }
    }
  }

  // A landing that stops short, on a conflict or a failed gate, leaves the
  // queue without landing.
  action Dequeue = {
    all {
      s.queued,
      not(s.delivered),
      s' = { queued: false, ...s }
    }
  }

  // `ci land` fast-forwards main to the exact head the gate passed, from the
  // front of the landing queue, which it then leaves. The push carries a
  // lease on the trunk the topic is based on, so it fails if trunk moved,
  // and the topic must rebase, republish, and pass again.
  action Land = {
    all {
      s.owner,
      s.active,
      s.published,
      not(s.conflict),
      not(s.delivered),
      s.queued,
      s.parentLanded,
      s.publishedHead == s.head,
      s.passedHead == s.head,
      s.base == s.mainHead,
      s' = {
        landedOnto: s.mainHead,
        mainHead: s.head,
        delivered: true,
        queued: false,
        ...s
      }
    }
  }

  // Releasing a topic leaves its workspace on main (--keep, or one that
  // `ci start` did not create) or drops it, so no workspace outlives its
  // owner.
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
    Queue,
    Dequeue,
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
    s.queued.in(Set(true, false))
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

  // Only a published topic that its owner is still landing holds the front
  // of the landing queue.
  val QueuedOnlyWhileLanding =
    not(s.queued) or (s.owner and s.active and s.published and not(s.delivered))

  // While a topic holds the front of the landing queue, trunk stays put, so
  // a topic that rebased there stays on trunk, and the clearance it takes is
  // never thrown away: no landing restarts because another one landed.
  // orKeep(s) makes these [A]_vars action properties, the only form of
  // action under [] that TLC accepts.
  temporal QueuedTopicStaysOnTrunk =
    always((
      (s.queued and next(s.queued) and s.base == s.mainHead) implies
        next(s.base) == next(s.mainHead)
    ).orKeep(s))

  // A topic lands only from the front of the landing queue.
  temporal LandsFromQueue =
    always(((not(s.delivered) and next(s.delivered)) implies s.queued).orKeep(s))
}
