---------------------- MODULE JjCi ----------------------
EXTENDS Naturals, FiniteSets, TLC

(***************************************************************************)
(* A bounded protocol model for the lifecycle enforced by ci.nu.            *)
(*                                                                       *)
(* The model abstracts command execution and remote failures. It tracks   *)
(* only the safety-relevant facts: workspace ownership, topic readiness,  *)
(* exact published head, conflict state, the head a landing gate passed,  *)
(* the stack parent, and the trunk tip.                                   *)
(* Validation is tagged with the head it checked and the head captured at *)
(* publication, so later edits cannot blur that relationship. Publication *)
(* also records that the topic was based on the current trunk.             *)
(*                                                                       *)
(* Landing is a fast-forward of main to the exact head a gate (the flake   *)
(* checks built locally by default, the spindle, or GitHub Actions)       *)
(* passed, pushed with a lease on the trunk the topic is based on. No     *)
(* forge merges: a squash, rebase, or merge commit would put a commit on  *)
(* main that no gate ran on.                                              *)
(*                                                                       *)
(* Landings go through one queue: a topic lands only from its front, and  *)
(* every other topic lands through the same queue, so trunk never moves   *)
(* while a topic holds the front. A topic that rebases there keeps the    *)
(* clearance it then takes. The model leaves out what moves trunk from     *)
(* outside the queue, such as another machine, which `ci land --attempts`  *)
(* retries. A train (`ci land --train`) lands several topics in one        *)
(* fast-forward from the front of the same queue; this model follows one   *)
(* topic and leaves trains out.                                           *)
(* agent/machine.mjs refines this protocol into the single-topic command  *)
(* states. Its Nushell host executes Publish via publish-topic, Queue via *)
(* with-landing-queue, GatePasses via wait-for-pipeline, and Land via       *)
(* advance-main. Only a failed Land lease retries; each rewritten head    *)
(* goes through Publish and GatePasses again. These guards remain in the  *)
(* effect implementations as well as in the agent.                        *)
(***************************************************************************)

CONSTANTS Heads, MainHeads
ASSUME Heads # {} /\ MainHeads # {} /\ Heads \cap MainHeads = {}

VARIABLES owner, active, head, base, conflict, validated, validatedHead,
          published, publishedHead, publishedValidated, publishedValidationHead,
          publishedConflictFree, publishedFresh, passedHead, parentLanded, mainHead,
          landedOnto, delivered, workspaceBase, queued

vars == <<owner, active, head, base, conflict, validated, validatedHead,
          published, publishedHead, publishedValidated, publishedValidationHead,
          publishedConflictFree, publishedFresh, passedHead, parentLanded, mainHead,
          landedOnto, delivered, workspaceBase, queued>>

(* Facts owned by the outside world: the gate's verdicts, the stack        *)
(* parent, and other topics landing on trunk.                             *)
worldVars == <<passedHead, parentLanded, mainHead>>

Init ==
    /\ owner = TRUE
    /\ active = TRUE
    /\ head \in Heads
    /\ base \in MainHeads
    /\ mainHead = base
    /\ conflict = FALSE
    /\ validated = FALSE
    /\ validatedHead = "none"
    /\ published = FALSE
    /\ publishedHead = "none"
    /\ publishedValidated = FALSE
    /\ publishedValidationHead = "none"
    /\ publishedConflictFree = FALSE
    /\ publishedFresh = FALSE
    /\ passedHead = "none"
    /\ landedOnto = "none"
    \* FALSE for a topic stacked on an unlanded parent.
    /\ parentLanded \in BOOLEAN
    /\ delivered = FALSE
    /\ workspaceBase = "topic"
    /\ queued = FALSE

Edit ==
    /\ owner /\ active /\ ~delivered
    /\ \E h \in Heads :
         /\ head' = h
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, base, conflict, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, landedOnto, delivered, workspaceBase,
                   queued>>
    /\ UNCHANGED worldVars

(* A rebase onto the current trunk rewrites every commit in the topic, so  *)
(* the head changes too.                                                  *)
RebaseClean ==
    /\ owner /\ active /\ ~conflict /\ ~delivered
    /\ base' = mainHead
    /\ \E h \in Heads :
         /\ head' = h
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, conflict, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, landedOnto, delivered, workspaceBase,
                   queued>>
    /\ UNCHANGED worldVars

RebaseConflicted ==
    /\ owner /\ active /\ ~conflict /\ ~delivered
    /\ base' = mainHead
    /\ \E h \in Heads :
         /\ head' = h
    /\ conflict' = TRUE
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, published, publishedHead,
                   publishedValidated, publishedValidationHead, publishedConflictFree, publishedFresh,
                   landedOnto, delivered, workspaceBase, queued>>
    /\ UNCHANGED worldVars

Resolve ==
    /\ owner /\ active /\ conflict /\ ~delivered
    /\ conflict' = FALSE
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, head, base, published, publishedHead,
                   publishedValidated, publishedValidationHead, publishedConflictFree, publishedFresh,
                   landedOnto, delivered, workspaceBase, queued>>
    /\ UNCHANGED worldVars

Validate ==
    /\ owner /\ active /\ ~conflict /\ ~delivered
    /\ validated' = TRUE
    /\ validatedHead' = head
    /\ UNCHANGED <<owner, active, head, base, conflict, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, landedOnto, delivered, workspaceBase,
                   queued>>
    /\ UNCHANGED worldVars

Publish ==
    /\ owner /\ active /\ validated /\ validatedHead = head
    /\ ~conflict /\ ~delivered
    /\ base = mainHead
    /\ publishedFresh' = (base = mainHead)
    /\ published' = TRUE
    /\ publishedHead' = head
    /\ publishedValidated' = validated
    /\ publishedValidationHead' = validatedHead
    /\ publishedConflictFree' = ~conflict
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   landedOnto, delivered, workspaceBase, queued>>
    /\ UNCHANGED worldVars

(* The gate checks an exact published head (CI on every push, the local   *)
(* gate when `ci land` runs) and passes it by commit, so a verdict never  *)
(* carries over to a rewritten head. A failing run simply never passes.   *)
GatePasses ==
    /\ published
    /\ passedHead' = publishedHead
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, parentLanded, mainHead,
                   landedOnto, delivered, workspaceBase, queued>>

(* The stack parent lands; the child is then based on trunk. *)
ParentLands ==
    /\ ~parentLanded
    /\ parentLanded' = TRUE
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, passedHead, mainHead,
                   landedOnto, delivered, workspaceBase, queued>>

(* Another topic lands first and moves trunk. It lands from the front of  *)
(* the landing queue, so not while this topic holds the front.             *)
TrunkAdvances ==
    /\ ~delivered /\ ~queued
    /\ \E m \in MainHeads \ {mainHead} :
         /\ mainHead' = m
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, passedHead, parentLanded,
                   landedOnto, delivered, workspaceBase, queued>>

(* `ci land` reaches the front of the landing queue, once the topic is    *)
(* published and its fast checks have passed.                             *)
Queue ==
    /\ owner /\ active /\ published /\ ~delivered /\ ~queued
    /\ queued' = TRUE
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED worldVars

(* A landing that stops short, on a conflict or a failed gate, leaves the  *)
(* queue without landing.                                                 *)
Dequeue ==
    /\ queued /\ ~delivered
    /\ queued' = FALSE
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED worldVars

(* `ci land` fast-forwards main to the exact head the gate passed, from    *)
(* the front of the landing queue, which it then leaves. The push carries *)
(* a lease on the trunk the topic is based on, so it fails if trunk moved, *)
(* and the topic must rebase, republish, and pass again.                  *)
Land ==
    /\ owner /\ active /\ published /\ ~conflict /\ ~delivered
    /\ queued
    /\ parentLanded
    /\ publishedHead = head
    /\ passedHead = head
    /\ base = mainHead
    /\ landedOnto' = mainHead
    /\ mainHead' = head
    /\ delivered' = TRUE
    /\ queued' = FALSE
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, passedHead, parentLanded, workspaceBase>>

(* Releasing a topic leaves its workspace on main (--keep, or one that    *)
(* `ci start` did not create) or drops it, so no workspace outlives its   *)
(* owner.                                                                 *)
Finish ==
    /\ owner /\ active /\ ~conflict
    /\ (delivered \/ ~published)
    /\ owner' = FALSE
    /\ active' = FALSE
    /\ workspaceBase' \in {"main", "dropped"}
    /\ UNCHANGED <<head, base, conflict, validated, validatedHead, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, landedOnto, delivered, queued>>
    /\ UNCHANGED worldVars

(* Abandoning discards unpublished work, conflicts included. The model    *)
(* omits PR closure, so a published topic cannot be abandoned.            *)
Abandon ==
    /\ owner /\ active /\ ~published
    /\ owner' = FALSE
    /\ active' = FALSE
    /\ conflict' = FALSE
    /\ workspaceBase' \in {"main", "dropped"}
    /\ UNCHANGED <<head, base, validated, validatedHead, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, publishedFresh, landedOnto, delivered, queued>>
    /\ UNCHANGED worldVars

Next == Edit \/ RebaseClean \/ RebaseConflicted \/ Resolve \/ Validate
        \/ Publish \/ GatePasses \/ ParentLands \/ TrunkAdvances
        \/ Queue \/ Dequeue \/ Land \/ Finish \/ Abandon

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ owner \in BOOLEAN
    /\ active \in BOOLEAN
    /\ head \in Heads
    /\ base \in MainHeads
    /\ conflict \in BOOLEAN
    /\ validated \in BOOLEAN
    /\ validatedHead \in Heads \cup {"none"}
    /\ published \in BOOLEAN
    /\ publishedHead \in Heads \cup {"none"}
    /\ publishedValidated \in BOOLEAN
    /\ publishedValidationHead \in Heads \cup {"none"}
    /\ publishedConflictFree \in BOOLEAN
    /\ publishedFresh \in BOOLEAN
    /\ passedHead \in Heads \cup {"none"}
    /\ parentLanded \in BOOLEAN
    /\ mainHead \in MainHeads \cup Heads
    /\ landedOnto \in MainHeads \cup {"none"}
    /\ delivered \in BOOLEAN
    /\ workspaceBase \in {"topic", "main", "dropped"}
    /\ queued \in BOOLEAN

NoPublishWhileUnsafe ==
    published => publishedHead \in Heads /\ publishedValidated /\ publishedConflictFree
PublishedFromFreshBase == published => publishedFresh
PublishedHeadWasValidated == published => publishedHead = publishedValidationHead
NoFinishWithConflict == ~(~owner /\ conflict)
FinishLeavesMain == ~active => workspaceBase \in {"main", "dropped"}
(* A workspace is freed only by its released owner, with nothing in flight. *)
NoDropWhilePending ==
    workspaceBase = "dropped" => ~owner /\ (delivered \/ ~published)

(* Not rocket science: main only ever holds a topic commit a gate passed.  *)
MainOnlyHoldsPassedHeads == mainHead \in Heads => mainHead = passedHead
(* Delivery is the published commit itself, not a forge-made copy of it,  *)
(* so change IDs, the impact declared for them, and ancestry checks        *)
(* survive landing.                                                        *)
DeliveryIsPublishedHead == delivered => mainHead = publishedHead
(* An edit or rebase after landing keeps the topic undelivered. *)
DeliveredHeadIsLocal == delivered => mainHead = head
(* A stacked topic lands only after its parent. *)
LandsAfterParent == delivered => parentLanded
(* Landing fast-forwards from the trunk the topic was based on: main moved *)
(* from the topic's own base, never from a trunk the gate did not test.   *)
LandingIsFastForward == delivered => landedOnto = base
(* Only a published topic that its owner is still landing holds the front *)
(* of the landing queue.                                                  *)
QueuedOnlyWhileLanding == queued => owner /\ active /\ published /\ ~delivered

(* While a topic holds the front of the landing queue, trunk stays put, so  *)
(* a topic that rebased there stays on trunk, and the clearance it takes   *)
(* is never thrown away: no landing restarts because another one landed.  *)
QueuedTopicStaysOnTrunk ==
    [][queued /\ queued' /\ base = mainHead => base' = mainHead']_vars
(* A topic lands only from the front of the landing queue. *)
LandsFromQueue == [][~delivered /\ delivered' => queued]_vars

===============================================================
