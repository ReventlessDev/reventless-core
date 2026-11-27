/**
DCB tag-scope inference (Phase 1 — pure core).

Derives DCB tag scope from the *global* slice graph instead of hand-placed
`@partitionTag` / `@crossPartition` / `@noTag` annotations. This module is
deliberately **schema-agnostic**: its input carries only the structural shape of
each slice (variant names + `*Id`-shaped fields), never an `S.t` schema and never
a tag-metadata flag. That is precisely what we are replacing — so both the runtime
(building shapes from `S.t` schemas, via `DcbTag.sliceShapeFromSchemas`) and the
VS Code tooling (building shapes from parsed `.res` source) can feed the same
`infer`. See `docs/plans/done/dcb-tag-scope-inference.md` § "Phase 1 design".

The four rules (over the representation):

1. **Owner / partition.** A slice's partition key is the key its *own* emitted
   events are identified by — computed as `producedKeys(S)` minus the keys `S`
   reads from a *foreign* producer (a consumed arm whose event type is produced by
   a different slice). For `AddProduct` (`ProductAdded({productId, categoryId})`,
   consuming `CategoryAdded({categoryId})`) the foreign-read `categoryId` is
   removed, leaving `productId`. Only when that leaves nothing is a key given
   back: one whose every foreign arm comes from a slice partitioned by that same
   key, since reading your own entity's events is identity, not a reference.
   That step depends on other slices' partitions, so it runs to a fixpoint.
   When several keys are left, the slice's chapter breaks the tie if exactly one
   of them is carried by every event its chapter writes.

2. **Cross-partition.** A key is cross-partition iff some slice reads it on a
   *foreign* consumed event while partitioned by something else *and* the key is
   another entity's partition. `AddProduct` reads `categoryId` (Category's
   partition) while partitioned by `productId` ⇒ `categoryId` is cross-partition.
   An arm that carries the slice's own partition is its own entity's history, so the
   other keys on it are not read by (`readByKeys`): `MoveContact`, partitioned by
   `contactId`, reads `ContactAdded({contactId, customerId})` and moves the contact
   to another customer without reading anything by `customerId`.

3. **Index vs payload.** A `*Id` on an *emitted* event is indexed iff it is the
   producing slice's own partition key. Foreign reference keys (e.g. `categoryId`
   on `ProductAdded`) are payload ⇒ not indexed ⇒ the sibling-leak GSI write never
   happens.

4. **Command scope.** A scalar key on a *command* is a query tag iff it is the
   slice's partition or a key the slice reads off a foreign event (rule 2's
   candidates). `ShipOrder({orderId, carrierId})` names the carrier as information:
   AND-ing it into the clause would hide every order event that does not carry it,
   so it is payload. See `commandPayloadKeys`.

A consumed arm marked `@readWhole` takes no part in any rule: the slice reads every event of the
type by the kind tag (`kindTagKey`), whatever its command carries. See `withWholeKinds`.
*/
/** A field the slice graph treats as an entity identity.

    Normally that is a `*Id` / `*Ids`-shaped name — the convention is the signal,
    and this module stays schema-agnostic by taking the name alone.

    `byTag` marks the exception: an identity the *name* does not declare, which an
    adapter recognized from an explicit `@partitionTag`. A domain's own identifier
    is often not suffixed — `sku`, `isbn`, `vin` — and without this the annotation
    naming one would be extracted as a hint and then dropped, because `seedOf`
    only honors a hint already among the produced keys. So the escape hatch would
    have worked for every field except the ones that need it.

    It is carried rather than folded in because removing the annotation removes
    the identity, which is exactly what the redundancy check has to know: a hint
    inference cannot reach without it is never redundant. */
type idField = {
  name: string,
  isList: bool,
  byTag?: bool,
  /** The tag key, when the field's type says it (an identity) rather than its name. */
  key?: string,
  /** The author asked for the tag (`@dcbTag`, `@partitionTag`, `@crossPartition`,
      `@compositePartitionTag`), so a command keeps it in its query (rule 4). */
  declared?: bool,
  /** The author marked it `@crossPartition`. On a consumed arm naming the slice's own
      key, the slice reads that event across partitions (a pair). */
  crossPartition?: bool,
}

/** One variant arm: its constructor name and the `*Id` fields it carries. `lookups`: the keys of
    the tags the author declared on fields that are no identity (a code a thing is found by,
    `ReferenceCode.tag`). They never take part in choosing a partition; an event is indexed by
    them, and a decision presented one reads by it on its own. */
type eventShape = {
  eventType: string,
  idFields: array<idField>,
  lookups?: array<string>,
  /** A consumed arm marked `@readWhole`: the slice reads every event of the type, by the kind
      tag, and the arm takes no part in its partition. */
  whole?: bool,
}

/**
The structural shape of one slice, the boundary type both adapters produce:
- `command` — the `*Id` fields on the slice's command,
- `consumed` — the arms (and their `*Id` fields) the slice reads,
- `produced` — the arms (and their `*Id` fields) the slice writes,
- `partitionHint` — an explicit `@partitionTag` escape hatch (when the dev marked
  the partition because the slice's own events legitimately carry two owned keys,
  e.g. `RecordProductDemand`). Overrides the inferred partition.
*/
type sliceShape = {
  sliceName: string,
  command: array<idField>,
  /** The keys of the declared tags on the slice's command that are no identity: the codes it is
      presented (`chargingToken`). */
  commandLookups?: array<string>,
  consumed: array<eventShape>,
  produced: array<eventShape>,
  partitionHint: option<string>,
  /** The chapter the slice sits in (`src/<Chapter>/<Kind>/…`), when it has one. */
  chapter?: string,
}

/** Derived scope for one tag key. */
type scope = Partition | CrossPartition | Payload

/** A slice reading another slice's event by its own partition key, across
    partitions, because it marked the key `@crossPartition` on that consumed arm. */
type pair = {
  reader: string,
  eventType: string,
  key: string,
  /** The slices that write the event, stored under another key. */
  writers: array<string>,
}

/**
The full derivation. `crossPartitionTagKeys` and `tagKeysByEventType` are the two
values the runtime threads today (via `DcbTag.extractCrossPartitionTagKeys` /
`mergeTagKeysByEventType`); under inference they are produced here.
*/
type derived = {
  /** sliceName -> its inferred partition key (absent when ambiguous). */
  partitionBySlice: dict<string>,
  /** tag key -> the name of a slice that owns it as its partition. */
  ownerByKey: dict<string>,
  /** keys read cross-partition by some slice (sorted, deduped). */
  crossPartitionTagKeys: array<string>,
  /** The pairs of the boundary, sorted by reader and event type. */
  crossPartitionPairs: array<pair>,
  /** The event types some slice reads whole (sorted). */
  wholeEventTypes: array<string>,
  /** produced eventType -> its indexed (non-payload) tag keys (sorted). */
  tagKeysByEventType: dict<array<string>>,
  /** (sliceName, reason) for slices whose partition couldn't be inferred. */
  ambiguities: array<(string, string)>,
}

/**
The tag key for a `*Id`-shaped field. A plural `*Ids: array<string>` shares the
singular producer's key (trailing `s` stripped — `productIds` -> `productId`);
a scalar `*Id` uses the field name verbatim. Mirrors the PPX's `*Ids` rule. An
identity-typed field carries its key, whatever it is called.
*/
let tagKeyOf = (f: idField): string =>
  if f.key->Option.isSome {
    f.key->Option.getUnsafe
  } else if f.isList && f.name->String.endsWith("s") {
    f.name->String.slice(~start=0, ~end=f.name->String.length - 1)
  } else {
    f.name
  }

let dedupSorted = (keys: array<string>): array<string> => {
  let seen = Set.make()
  keys->Array.forEach(k => seen->Set.add(k))
  Array.fromIterator(seen->Set.values)->Array.toSorted((a, b) => String.compare(a, b))
}

let keysOfEvent = (e: eventShape): array<string> => e.idFields->Array.map(tagKeyOf)

let producedKeys = (s: sliceShape): array<string> =>
  dedupSorted(s.produced->Array.flatMap(keysOfEvent))

/**
The keys every id-carrying event the slice writes carries: the only keys that can
be its partition. A key one of its events lacks cannot tag that event, so the
slice could not read its own history back by it (a question's `QuestionReopened`
has no `replyId`, though its `AnswerMarked` does).
*/
let sharedProducedKeys = (s: sliceShape): array<string> =>
  switch s.produced->Array.filter(e => e.idFields->Array.length > 0) {
  | [] => []
  | events =>
    producedKeys(s)->Array.filter(k => events->Array.every(e => e->keysOfEvent->Array.includes(k)))
  }

/** The consumed arms a slice reads by its tags: every one but those it reads whole. */
let partitionArms = (s: sliceShape): array<eventShape> =>
  s.consumed->Array.filter(e => e.whole != Some(true))

/** The types a slice reads whole (sorted). */
let wholeTypesOf = (s: sliceShape): array<string> =>
  s.consumed->Array.filter(e => e.whole == Some(true))->Array.map(e => e.eventType)->dedupSorted

/** The key of the tag every event of a kind read whole carries; its value is the event type. A
    field name cannot hold the dot, so no app's own tag shares it. */
let kindTagKey = "reventless.kind"

/**
The scope a boundary's whole reads add: the kind key is read across partitions, and each type read
whole is indexed by it, so its writers tag it and move its fence.
*/
let withWholeKinds = (
  ~wholeEventTypes: array<string>,
  ~crossPartitionTagKeys: array<string>,
  ~tagKeysByEventType: dict<array<string>>,
): (array<string>, dict<array<string>>) =>
  switch wholeEventTypes {
  | [] => (crossPartitionTagKeys, tagKeysByEventType)
  | types =>
    let tagKeys = tagKeysByEventType->Dict.copy
    types->Array.forEach(t =>
      tagKeys->Dict.set(
        t,
        dedupSorted(tagKeys->Dict.get(t)->Option.getOr([])->Array.concat([kindTagKey])),
      )
    )
    (dedupSorted(crossPartitionTagKeys->Array.concat([kindTagKey])), tagKeys)
  }

let consumedKeys = (s: sliceShape): array<string> =>
  dedupSorted(s->partitionArms->Array.flatMap(keysOfEvent))

/**
Keys the command carries as a **scalar** (`*Id: string`, not `*Ids: array<string>`).
A scalar tag is AND-ed with the partition into one composite clause unless it is
read cross-partition, so only a scalar foreign reference needs the cross-partition
fan. A foreign key the command carries *only* as an array already fans per element
and stays partition-scoped (it reads the foreign entity's own partition) — the
`PlaceOrder`/`productIds` shape — so it is **not** cross-partition.
*/
let commandScalarKeys = (s: sliceShape): array<string> =>
  dedupSorted(s.command->Array.filter(f => !f.isList)->Array.map(tagKeyOf))

/**
Infers DCB tag scope for a set of slices (one DCB consistency boundary / plugin).
Pure and total — never throws; unresolvable partitions land in `ambiguities`.
*/
/**
The keys a slice reads from a *foreign* event — a consumed arm whose event type
the slice does **not** itself produce. These are the candidate cross-entity
references; they cannot be the slice's own partition. Defined on a single shape
so it works both globally (in `infer`) and per-slice (in the GWT harness, which
sees only one slice).
*/
let foreignConsumedKeys = (s: sliceShape): array<string> => {
  let ownProduced = Set.make()
  s.produced->Array.forEach(e => ownProduced->Set.add(e.eventType))
  dedupSorted(
    s->partitionArms->Array.flatMap(e => ownProduced->Set.has(e.eventType) ? [] : e->keysOfEvent),
  )
}

/**
The keys a slice reads by on `arms`, once its partition is known. An arm that carries the
partition is the slice's own entity's history, whoever wrote it: its other keys are what that
entity says (the customer a contact belongs to), not keys the slice reads by. A key the author
declared on such an arm is read by all the same. Without a partition every key counts.

Rule 1 says the same of a key read back off the slice's own entity; rules 2 and 4 use this.
*/
let readByKeys = (arms: array<eventShape>, ~partition: option<string>): array<string> => {
  let declared = (f: idField) => f.declared->Option.getOr(false)
  dedupSorted(
    arms->Array.flatMap(e =>
      switch partition {
      | Some(p) if e->keysOfEvent->Array.includes(p) =>
        e.idFields->Array.filter(declared)->Array.map(tagKeyOf)
      | _ => e->keysOfEvent
      }
    ),
  )
}

/** The arms a slice reads by its tags that it does not itself produce. */
let foreignArms = (s: sliceShape): array<eventShape> => {
  let own = Set.make()
  s.produced->Array.forEach(e => own->Set.add(e.eventType))
  s->partitionArms->Array.filter(e => !(own->Set.has(e.eventType)))
}

/** The slices that write `eventType`. */
let producersOf = (slices: array<sliceShape>, eventType: string): array<sliceShape> =>
  slices->Array.filter(p => p.produced->Array.some(e => e.eventType == eventType))

/** The keys an arm marks `@crossPartition`. */
let markedKeys = (e: eventShape): array<string> =>
  e.idFields->Array.filter(f => f.crossPartition == Some(true))->Array.map(tagKeyOf)

/**
The foreign arms of `s` that carry `key` while some slice writes them under another
key, so a read by `key` within its partition does not reach them. An event no slice
of the boundary writes is left out: where it is stored is not known here.
*/
let armsStoredElsewhere = (
  s: sliceShape,
  slices: array<sliceShape>,
  ~key: string,
  ~partitionBySlice: dict<string>,
): array<eventShape> =>
  s
  ->foreignArms
  ->Array.filter(e =>
    e->keysOfEvent->Array.includes(key) &&
      slices
      ->producersOf(e.eventType)
      ->Array.some(p => partitionBySlice->Dict.get(p.sliceName) != Some(key))
  )

/**
The pairs of a boundary: each slice's arms stored elsewhere that it marks
`@crossPartition` by its own partition key. A key the boundary already reads across
partitions needs no pair.
*/
let pairsOf = (
  slices: array<sliceShape>,
  ~partitionBySlice: dict<string>,
  ~crossPartitionTagKeys: array<string>,
): array<pair> =>
  slices
  ->Array.flatMap(s =>
    switch partitionBySlice->Dict.get(s.sliceName) {
    | Some(key) if !(crossPartitionTagKeys->Array.includes(key)) =>
      s
      ->armsStoredElsewhere(slices, ~key, ~partitionBySlice)
      ->Array.filter(e => e->markedKeys->Array.includes(key))
      ->Array.map(e => {
        reader: s.sliceName,
        eventType: e.eventType,
        key,
        writers: slices->producersOf(e.eventType)->Array.map(p => p.sliceName)->dedupSorted,
      })
    | _ => []
    }
  )
  ->Array.toSorted((a, b) =>
    switch String.compare(a.reader, b.reader) {
    | 0. => String.compare(a.eventType, b.eventType)
    | c => c
    }
  )

/** Key -> the event types `reader` reads by it across partitions. */
let pairEventTypes = (pairs: array<pair>, ~reader: string): dict<array<string>> => {
  let byKey = Dict.make()
  pairs->Array.forEach(p =>
    if p.reader == reader {
      byKey->Dict.set(p.key, byKey->Dict.get(p.key)->Option.getOr([])->Array.concat([p.eventType]))
    }
  )
  byKey
}

/** Key -> the event types with a pair fence on it, whoever reads them: what the
    event log keeps a fence item for, and its writers move. */
let pairFenceTypes = (pairs: array<pair>): dict<array<string>> => {
  let byKey = Dict.make()
  pairs->Array.forEach(p => {
    let types = byKey->Dict.get(p.key)->Option.getOr([])
    if !(types->Array.includes(p.eventType)) {
      byKey->Dict.set(p.key, types->Array.concat([p.eventType]))
    }
  })
  byKey
}

/** Rule 1's outcome for a boundary, before the scope rules build on it. */
type partitionResolution = {
  /** sliceName -> its partition key (absent when unresolved). */
  partitionBySlice: dict<string>,
  /** sliceName -> the keys rule 1 left standing; one entry means resolved. */
  candidatesBySlice: dict<array<string>>,
  /** sliceName -> (produced key, the foreign arms that kept it from the slice). */
  blockersBySlice: dict<array<(string, array<string>)>>,
  /** (sliceName, reason) for slices whose partition couldn't be inferred. */
  ambiguities: array<(string, string)>,
}

let sameAssignment = (a: dict<string>, b: dict<string>): bool => {
  let entries = d => d->Dict.toArray->Array.toSorted(((x, _), (y, _)) => String.compare(x, y))
  entries(a) == entries(b)
}

/**
Rule 1 over a whole boundary.

1. **Seeds.** A slice whose events carry a single key is partitioned by it, whatever
   it reads; an explicit `@partitionTag` naming a produced key is a seed too.
2. **Subtraction.** Otherwise, `sharedProducedKeys − foreignConsumedKeys`: only a key
   every event the slice writes carries can be its partition. One key left
   is the partition; several go to the chapter (4), then to `@partitionTag`.
3. **Give-back.** Only when the subtraction leaves nothing: a key comes back when
   every foreign arm carrying it is produced by a slice partitioned by that key.
   An unseen producer makes the arm a reference. An unresolved producer counts as
   possibly partitioned by any key it writes, which breaks cycles such as two
   slices each reading the other's event; the answer counts only once a further
   pass changes nothing, so that optimism never decides it alone.
4. **Chapter.** When several keys are left, keep the ones every id-carrying event
   written in the slice's chapter carries. `PlaceOrder` is left with `orderId` and
   `customerId`, whose reads never show the customer to be a reference; every
   event under `Order/` carries `orderId`, and only some carry `customerId`. Only a
   single survivor decides — a join such as `RecordProductDemand`, whose chapter's
   events all carry both ids, stays ambiguous. It is a tie-breaker, not a rule:
   it never overrides a seed, the subtraction or the give-back, and moving a slice
   to another chapter can change only a partition this step decided.

Applying the give-back everywhere would be wrong: `AddProduct` reads
`CategoryAdded({categoryId})` from a slice partitioned by `categoryId`, which
would hand `categoryId` back and leave it two candidates.
*/
/**
Chapter -> the keys every id-carrying event written in that chapter carries: what the
chapter says its slices are about. Rule 1's tie-break reads it, and so does the check
that decides whether a `@partitionTag` inference disagrees with is the author's
mistake or inference's (`DcbValidation.validatePartitionHintsVsInference`).
*/
let chapterKeys = (slices: array<sliceShape>): dict<array<string>> => {
  let byChapter = Dict.make()
  slices->Array.forEach(s =>
    s.chapter->Option.forEach(chapter => {
      let events = s.produced->Array.filter(e => e.idFields->Array.length > 0)
      events->Array.forEach(
        e => {
          let keys = e->keysOfEvent
          let shared = switch byChapter->Dict.get(chapter) {
          | Some(prev) => prev->Array.filter(k => keys->Array.includes(k))
          | None => dedupSorted(keys)
          }
          byChapter->Dict.set(chapter, shared)
        },
      )
    })
  )
  byChapter
}

let resolvePartitions = (slices: array<sliceShape>): partitionResolution => {
  let producersByEventType: dict<array<sliceShape>> = Dict.make()
  slices->Array.forEach(s =>
    s.produced->Array.forEach(e => {
      let prev = producersByEventType->Dict.get(e.eventType)->Option.getOr([])
      if !(prev->Array.some(p => p.sliceName == s.sliceName)) {
        producersByEventType->Dict.set(e.eventType, prev->Array.concat([s]))
      }
    })
  )
  let chapterKeys = chapterKeys(slices)
  let chapterKeysOf = (s: sliceShape) => s.chapter->Option.flatMap(c => chapterKeys->Dict.get(c))
  let byChapter = (s: sliceShape, candidates) =>
    switch s->chapterKeysOf {
    | Some(keys) =>
      switch candidates->Array.filter(k => keys->Array.includes(k)) {
      | [k] => [k]
      | _ => candidates
      }
    | None => candidates
    }
  // An arm is identity evidence for `k` iff every producer of its event type is
  // (or, while unresolved, could be) partitioned by `k`.
  let armIsIdentity = (e: eventShape, k, known: dict<string>) =>
    switch producersByEventType->Dict.get(e.eventType) {
    | None | Some([]) => false
    | Some(producers) =>
      producers->Array.every(p =>
        switch known->Dict.get(p.sliceName) {
        | Some(pk) => pk == k
        | None => producedKeys(p)->Array.includes(k)
        }
      )
    }
  let blockersOf = (s: sliceShape, known) =>
    producedKeys(s)->Array.filterMap(k => {
      let arms =
        s
        ->foreignArms
        ->Array.filter(e => e->keysOfEvent->Array.includes(k) && !armIsIdentity(e, k, known))
        ->Array.map(e => e.eventType)
      arms->Array.length > 0 ? Some((k, arms)) : None
    })
  let seedOf = (s: sliceShape) => {
    let produced = producedKeys(s)
    switch (s.partitionHint, produced) {
    | (Some(h), _) if produced->Array.includes(h) => Some(h)
    | (_, [single]) => Some(single)
    | _ => None
    }
  }
  // Subtraction and give-back choose only among the keys every written event
  // carries (`sharedProducedKeys`); seeds stay as they are.
  let subtracted = (s: sliceShape) => {
    let foreign = foreignConsumedKeys(s)
    sharedProducedKeys(s)->Array.filter(k => !(foreign->Array.includes(k)))
  }
  let candidatesOf = (s: sliceShape, known) =>
    switch seedOf(s) {
    | Some(k) => [k]
    | None =>
      switch subtracted(s) {
      | [] =>
        let blocked = s->blockersOf(known)->Array.map(((k, _)) => k)
        s->byChapter(sharedProducedKeys(s)->Array.filter(k => !(blocked->Array.includes(k))))
      | remaining => s->byChapter(remaining)
      }
    }

  let pass = known => {
    let next = Dict.make()
    slices->Array.forEach(s =>
      switch candidatesOf(s, known) {
      | [k] => next->Dict.set(s.sliceName, k)
      | _ => ()
      }
    )
    next
  }
  // Each pass can resolve at most one more link of a chain, so a boundary that
  // settles does so within one pass per slice; the extra pass confirms it.
  let rec settle = (known, remaining) => {
    let next = pass(known)
    if sameAssignment(next, known) {
      (next, true)
    } else if remaining == 0 {
      (next, false)
    } else {
      settle(next, remaining - 1)
    }
  }
  let (settled, converged) = settle(Dict.make(), slices->Array.length + 1)
  let previous = pass(settled)

  let partitionBySlice = Dict.make()
  let candidatesBySlice = Dict.make()
  let blockersBySlice = Dict.make()
  let ambiguities = []
  slices->Array.forEach(s => {
    let candidates = candidatesOf(s, settled)
    candidatesBySlice->Dict.set(s.sliceName, candidates)
    switch candidates {
    | _ if !converged && settled->Dict.get(s.sliceName) != previous->Dict.get(s.sliceName) =>
      ambiguities->Array.push((
        s.sliceName,
        `partition inference did not settle — the slices it reads from keep changing each other's partition. Add an explicit @partitionTag`,
      ))
    | [k] => partitionBySlice->Dict.set(s.sliceName, k)
    | [] =>
      // Name the arms that took the key. Almost always a lifecycle arm
      // declaring the id the slice is already partitioned by, where the fix is
      // to drop the field rather than to annotate around it.
      let blockers = s->blockersOf(settled)
      blockersBySlice->Dict.set(s.sliceName, blockers)
      let blame =
        blockers
        ->Array.map(((key, arms)) => `${arms->Array.join("/")} declares ${key}`)
        ->Array.join("; ")
      ambiguities->Array.push((
        s.sliceName,
        `no own partition key — every produced *Id is read from a foreign producer (${blame}). If that field is this slice's own partition, remove it from the consumed arm; if the slice really is a pure join, add an explicit @partitionTag`,
      ))
    | many =>
      let chapterNote = switch (s.chapter, s->chapterKeysOf) {
      | (Some(chapter), Some(keys)) =>
        ` The ${chapter} chapter does not decide: the ids every event in it carries are [${keys->Array.join(
            ", ",
          )}].`
      | _ => ""
      }
      ambiguities->Array.push((
        s.sliceName,
        `multiple candidate partition keys (${many->Array.join(
            ", ",
          )}) — add an explicit @partitionTag.${chapterNote}`,
      ))
    }
  })
  {partitionBySlice, candidatesBySlice, blockersBySlice, ambiguities}
}

/**
Which consumed arms cost a slice its partition — the actionable half of the
"no own partition key" ambiguity, seen from this slice alone.

A slice whose produced keys all ride consumed arms from other producers, and
whose arms cannot be given back, is left with nothing. In practice that is almost
always one mistake: a *lifecycle* arm naming the id the slice is already
partitioned by, which reads as "this id comes from a foreign producer".

The ambiguity message can only say a partition was not found. This says which arm
to delete, which is the whole difference between a diagnostic and a puzzle.

Alone, no producer is in sight, so every foreign arm is a reference. Returns one
entry per produced key a foreign arm claims, naming those arms. Empty when the
slice has a partition or when too many keys are left (answered by `@partitionTag`).
*/
let partitionBlockers = (s: sliceShape): array<(string, array<string>)> =>
  resolvePartitions([s]).blockersBySlice->Dict.get(s.sliceName)->Option.getOr([])

/**
Per-slice cross-partition keys for the test harness, which has no global owner
map: a foreign-read key that is not the slice's own partition is read across
partitions. Matches `infer`'s global rule 2 for the common "reference another
entity" case; the harness unions this with any explicit `@crossPartition`
annotation so capacity/escape-hatch reads remain covered.
*/
let crossPartitionForSlice = (s: sliceShape): array<string> => {
  let scalar = commandScalarKeys(s)
  let partition = resolvePartitions([s]).partitionBySlice->Dict.get(s.sliceName)
  let foreign = s->foreignArms->readByKeys(~partition)
  // A foreign read is cross-partition only when the command carries the key as a
  // scalar (must be fanned); an array-only foreign key auto-fans partition-scoped.
  foreign->Array.filter(k => Some(k) != partition && scalar->Array.includes(k))
}

/**
Rule 4: the scalar command keys that stay out of the slice's decision query.

A key stays in when it is the partition, when the slice reads it off a foreign
event, when the boundary reads it across partitions, when the author declared it
on the command or on one of the slice's own arms (an M:N capacity read's
`@crossPartition` sits on the event), or when the command also carries it as a
list. Anything else only names another thing, and the fence is the partition.
*/
let commandPayloadKeys = (s: sliceShape, ~partition: string, ~crossPartition: array<string>): array<
  string,
> => {
  let foreign = s->foreignArms->readByKeys(~partition=Some(partition))
  let declared = (f: idField) => f.declared->Option.getOr(false)
  let pinned =
    s.command
    ->Array.filter(f => f.isList || declared(f))
    ->Array.concat(
      Array.concat(s->partitionArms, s.produced)->Array.flatMap(e =>
        e.idFields->Array.filter(declared)
      ),
    )
    ->Array.map(tagKeyOf)
  commandScalarKeys(s)->Array.filter(k =>
    k != partition &&
    !(foreign->Array.includes(k)) &&
    !(crossPartition->Array.includes(k)) &&
    !(pinned->Array.includes(k))
  )
}

let infer = (slices: array<sliceShape>): derived => {
  let {partitionBySlice, ambiguities} = resolvePartitions(slices)

  // owner map + the set of keys that are *some* entity's partition.
  let ownerByKey = Dict.make()
  let ownedPartitionKeys = Set.make()
  slices->Array.forEach(s =>
    switch partitionBySlice->Dict.get(s.sliceName) {
    | Some(k) =>
      ownedPartitionKeys->Set.add(k)
      switch ownerByKey->Dict.get(k) {
      | Some(_) => ()
      | None => ownerByKey->Dict.set(k, s.sliceName)
      }
    | None => ()
    }
  )

  // Rule 2 — a key read on a foreign consumed event that is another entity's
  // partition (and not this slice's own partition) is cross-partition — but only
  // when the command carries it as a SCALAR. A foreign key the command carries
  // only as an array auto-fans per element and stays partition-scoped (it reads
  // the foreign entity's own partition), so it is not cross-partition.
  let crossKeys = Set.make()
  slices->Array.forEach(s => {
    let own = partitionBySlice->Dict.get(s.sliceName)
    let scalar = commandScalarKeys(s)
    s
    ->partitionArms
    ->readByKeys(~partition=own)
    ->Array.forEach(k =>
      if ownedPartitionKeys->Set.has(k) && Some(k) != own && scalar->Array.includes(k) {
        crossKeys->Set.add(k)
      }
    )
  })
  // A code the command is presented and an event it reads is tagged by (`chargingToken` on
  // *start session* and on *driver registered*) finds the thing it names wherever that is: read on
  // a clause of its own, never AND-ed with the slice's own key, which that event does not carry.
  slices->Array.forEach(s => {
    let presented = s.commandLookups->Option.getOr([])
    s
    ->partitionArms
    ->Array.forEach(e =>
      e.lookups
      ->Option.getOr([])
      ->Array.forEach(
        k =>
          if presented->Array.includes(k) {
            crossKeys->Set.add(k)
          },
      )
    )
  })
  let crossPartitionTagKeys =
    Array.fromIterator(crossKeys->Set.values)->Array.toSorted((a, b) => String.compare(a, b))

  // Rule 3 — a produced key is indexed iff it is the producing slice's own
  // partition OR some slice issues a decision read of *that event type* by it
  // (the key appears on a consumed arm naming the event type). Foreign reference
  // keys that nobody reads this event type by are payload ⇒ no GSI write ⇒ the
  // sibling leak is impossible. The read-by-anybody arm is what keeps a composite
  // own-stream read (e.g. ProductDemandRecorded read by orderId) — and an M:N
  // capacity read — correctly indexed without a hand annotation.
  let readKeysByEventType = Dict.make()
  slices->Array.forEach(s =>
    s
    ->partitionArms
    ->Array.forEach(e => {
      let prev = readKeysByEventType->Dict.get(e.eventType)->Option.getOr([])
      readKeysByEventType->Dict.set(e.eventType, prev->Array.concat(e->keysOfEvent))
    })
  )
  let tagKeysByEventType = Dict.make()
  slices->Array.forEach(s => {
    let own = partitionBySlice->Dict.get(s.sliceName)
    s.produced->Array.forEach(e => {
      let readKeys = readKeysByEventType->Dict.get(e.eventType)->Option.getOr([])
      let indexed = e->keysOfEvent->Array.filter(k => Some(k) == own || readKeys->Array.includes(k))
      // A tag the author declared on a field that is no identity is the event's to be found by:
      // indexed always.
      let indexed = Array.concat(indexed, e.lookups->Option.getOr([]))
      tagKeysByEventType->Dict.set(e.eventType, dedupSorted(indexed))
    })
  })

  let crossPartitionPairs = pairsOf(slices, ~partitionBySlice, ~crossPartitionTagKeys)

  let wholeEventTypes = slices->Array.flatMap(wholeTypesOf)->dedupSorted
  let (crossPartitionTagKeys, tagKeysByEventType) = withWholeKinds(
    ~wholeEventTypes,
    ~crossPartitionTagKeys,
    ~tagKeysByEventType,
  )

  {
    partitionBySlice,
    ownerByKey,
    crossPartitionTagKeys,
    crossPartitionPairs,
    wholeEventTypes,
    tagKeysByEventType,
    ambiguities,
  }
}
