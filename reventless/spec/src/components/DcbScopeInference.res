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
   removed, leaving `productId`. No fixpoint needed.

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

/**
Which consumed arms cost a slice its partition — the actionable half of the
"no own partition key" ambiguity.

Rule 1 subtracts `foreignConsumedKeys` from `producedKeys`, so a slice whose only
produced key is also declared on a consumed arm it does not itself produce is left
with nothing. In practice that is almost always one mistake: a *lifecycle* arm
naming the id it is already partitioned by (`ProductAdded({productId})` on a slice
whose every event carries `productId`), which reads as "this id comes from a
foreign producer" when it is in fact this slice's own partition.

The ambiguity message can only say a partition was not found. This says which arm
to delete, which is the whole difference between a diagnostic and a puzzle — so it
is here, beside the rule that produces the ambiguity, rather than duplicated by
each surface that reports one.

Returns one entry per produced key that a foreign arm claims, naming those arms.
Empty when the slice has a partition (nothing to explain) or when the produced
keys are simply too many (a different ambiguity, answered by `@partitionTag`).
*/
let partitionBlockers = (s: sliceShape): array<(string, array<string>)> => {
  let foreign = foreignConsumedKeys(s)
  let ownProduced = Set.make()
  s.produced->Array.forEach(e => ownProduced->Set.add(e.eventType))
  producedKeys(s)
  ->Array.filter(k => foreign->Array.includes(k))
  ->Array.map(k => (
    k,
    s.consumed
    ->Array.filter(e => !(ownProduced->Set.has(e.eventType)) && e->keysOfEvent->Array.includes(k))
    ->Array.map(e => e.eventType),
  ))
}

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
  let partition = switch s.partitionHint {
  | Some(h) if producedKeys(s)->Array.includes(h) => Some(h)
  | _ =>
    switch producedKeys(s)->Array.filter(k => !(foreign->Array.includes(k))) {
    | [single] => Some(single)
    | _ => None
    }
  }
  // A foreign read is cross-partition only when the command carries the key as a
  // scalar (must be fanned); an array-only foreign key auto-fans partition-scoped.
  foreign->Array.filter(k => Some(k) != partition && scalar->Array.includes(k))
}

let infer = (slices: array<sliceShape>): derived => {
  // Rule 1 — partition(S) = producedKeys(S) \ foreignConsumedKeys(S), where a
  // foreign-consumed key rides a consumed arm the slice does not itself produce.
  // An explicit @partitionTag hint overrides the derivation (escape hatch for
  // slices whose own events legitimately carry two owned keys).
  let partitionBySlice = Dict.make()
  let ambiguities = []
  slices->Array.forEach(s => {
    let produced = producedKeys(s)
    switch s.partitionHint {
    | Some(h) if produced->Array.includes(h) => partitionBySlice->Dict.set(s.sliceName, h)
    | _ =>
      let foreign = foreignConsumedKeys(s)
      switch produced->Array.filter(k => !(foreign->Array.includes(k))) {
      | [single] => partitionBySlice->Dict.set(s.sliceName, single)
      | [] =>
        // Name the arms that took the key. Almost always a lifecycle arm
        // declaring the id the slice is already partitioned by, where the fix is
        // to drop the field rather than to annotate around it.
        let blame =
          partitionBlockers(s)
          ->Array.map(((key, arms)) => `${arms->Array.join("/")} declares ${key}`)
          ->Array.join("; ")
        let _ = ambiguities->Array.push((
          s.sliceName,
          `no own partition key — every produced *Id is read from a foreign producer (${blame}). If that field is this slice's own partition, remove it from the consumed arm; if the slice really is a pure join, add an explicit @partitionTag`,
        ))
      | many =>
        let _ = ambiguities->Array.push((
          s.sliceName,
          `multiple candidate partition keys (${many->Array.join(", ")}) — add an explicit @partitionTag`,
        ))
      }
    }
  })

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
    s->consumedKeys->Array.forEach(k =>
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
      let indexed =
        e->keysOfEvent->Array.filter(k => Some(k) == own || readKeys->Array.includes(k))
      tagKeysByEventType->Dict.set(e.eventType, dedupSorted(indexed))
    })
  })

  {partitionBySlice, ownerByKey, crossPartitionTagKeys, tagKeysByEventType, ambiguities}
}
