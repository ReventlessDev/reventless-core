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

The three rules (over the representation):

1. **Owner / partition.** A slice's partition key is the key its *own* emitted
   events are identified by — computed as `producedKeys(S)` minus the keys `S`
   reads from a *foreign* producer (a consumed arm whose event type is produced by
   a different slice). For `AddProduct` (`ProductAdded({productId, categoryId})`,
   consuming `CategoryAdded({categoryId})`) the foreign-read `categoryId` is
   removed, leaving `productId`. Only when that leaves nothing is a key given
   back: one whose every foreign arm comes from a slice partitioned by that same
   key, since reading your own entity's events is identity, not a reference.
   That step depends on other slices' partitions, so it runs to a fixpoint.

2. **Cross-partition.** A key is cross-partition iff some slice reads it on a
   *foreign* consumed event while partitioned by something else *and* the key is
   another entity's partition. `AddProduct` reads `categoryId` (Category's
   partition) while partitioned by `productId` ⇒ `categoryId` is cross-partition.

3. **Index vs payload.** A `*Id` on an *emitted* event is indexed iff it is the
   producing slice's own partition key. Foreign reference keys (e.g. `categoryId`
   on `ProductAdded`) are payload ⇒ not indexed ⇒ the sibling-leak GSI write never
   happens.
*/
/** A `*Id` / `*Ids`-shaped field, identified by name only (no schema, no tag flag). */
type idField = {name: string, isList: bool}

/** One variant arm: its constructor name and the `*Id` fields it carries. */
type eventShape = {eventType: string, idFields: array<idField>}

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
  consumed: array<eventShape>,
  produced: array<eventShape>,
  partitionHint: option<string>,
}

/** Derived scope for one tag key. */
type scope = Partition | CrossPartition | Payload

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
  /** produced eventType -> its indexed (non-payload) tag keys (sorted). */
  tagKeysByEventType: dict<array<string>>,
  /** (sliceName, reason) for slices whose partition couldn't be inferred. */
  ambiguities: array<(string, string)>,
}

/**
The tag key for a `*Id`-shaped field. A plural `*Ids: array<string>` shares the
singular producer's key (trailing `s` stripped — `productIds` -> `productId`);
a scalar `*Id` uses the field name verbatim. Mirrors the PPX's `*Ids` rule.
*/
let tagKeyOf = (f: idField): string =>
  if f.isList && f.name->String.endsWith("s") {
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

let consumedKeys = (s: sliceShape): array<string> =>
  dedupSorted(s.consumed->Array.flatMap(keysOfEvent))

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
    s.consumed->Array.flatMap(e => ownProduced->Set.has(e.eventType) ? [] : e->keysOfEvent),
  )
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
2. **Subtraction.** Otherwise, `producedKeys − foreignConsumedKeys`. One key left
   is the partition; several is an ambiguity only `@partitionTag` resolves.
3. **Give-back.** Only when the subtraction leaves nothing: a key comes back when
   every foreign arm carrying it is produced by a slice partitioned by that key.
   An unseen producer makes the arm a reference. An unresolved producer counts as
   possibly partitioned by any key it writes, which breaks cycles such as two
   slices each reading the other's event; the answer counts only once a further
   pass changes nothing, so that optimism never decides it alone.

Applying the give-back everywhere would be wrong: `AddProduct` reads
`CategoryAdded({categoryId})` from a slice partitioned by `categoryId`, which
would hand `categoryId` back and leave it two candidates.
*/
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
  let foreignArms = (s: sliceShape) => {
    let own = Set.make()
    s.produced->Array.forEach(e => own->Set.add(e.eventType))
    s.consumed->Array.filter(e => !(own->Set.has(e.eventType)))
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
  let subtracted = (s: sliceShape) => {
    let foreign = foreignConsumedKeys(s)
    producedKeys(s)->Array.filter(k => !(foreign->Array.includes(k)))
  }
  let candidatesOf = (s: sliceShape, known) =>
    switch seedOf(s) {
    | Some(k) => [k]
    | None =>
      switch subtracted(s) {
      | [] =>
        let blocked = s->blockersOf(known)->Array.map(((k, _)) => k)
        producedKeys(s)->Array.filter(k => !(blocked->Array.includes(k)))
      | remaining => remaining
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
      ambiguities->Array.push((
        s.sliceName,
        `multiple candidate partition keys (${many->Array.join(
            ", ",
          )}) — add an explicit @partitionTag`,
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
  let foreign = foreignConsumedKeys(s)
  let scalar = commandScalarKeys(s)
  let partition = resolvePartitions([s]).partitionBySlice->Dict.get(s.sliceName)
  // A foreign read is cross-partition only when the command carries the key as a
  // scalar (must be fanned); an array-only foreign key auto-fans partition-scoped.
  foreign->Array.filter(k => Some(k) != partition && scalar->Array.includes(k))
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
    ->consumedKeys
    ->Array.forEach(k =>
      if ownedPartitionKeys->Set.has(k) && Some(k) != own && scalar->Array.includes(k) {
        crossKeys->Set.add(k)
      }
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
    s.consumed->Array.forEach(e => {
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
      tagKeysByEventType->Dict.set(e.eventType, dedupSorted(indexed))
    })
  })

  {partitionBySlice, ownerByKey, crossPartitionTagKeys, tagKeysByEventType, ambiguities}
}
