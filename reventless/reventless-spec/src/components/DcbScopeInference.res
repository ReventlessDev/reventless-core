/**
DCB tag-scope inference (Phase 1 — pure core).

Derives DCB tag scope from the *global* slice graph instead of hand-placed
`@partitionTag` / `@crossPartition` / `@noTag` annotations. This module is
deliberately **schema-agnostic**: its input carries only the structural shape of
each slice (variant names + `*Id`-shaped fields), never an `S.t` schema and never
a tag-metadata flag. That is precisely what we are replacing — so both the runtime
(building shapes from `S.t` schemas, via `DcbTag.sliceShapeFromSchemas`) and the
VS Code tooling (building shapes from parsed `.res` source) can feed the same
`infer`. See `docs/plans/dcb-tag-scope-inference.md` § "Phase 1 design".

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
- `produced` — the arms (and their `*Id` fields) the slice writes.
*/
type sliceShape = {
  sliceName: string,
  command: array<idField>,
  consumed: array<eventShape>,
  produced: array<eventShape>,
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
Infers DCB tag scope for a set of slices (one DCB consistency boundary / plugin).
Pure and total — never throws; unresolvable partitions land in `ambiguities`.
*/
let infer = (slices: array<sliceShape>): derived => {
  // eventType -> a slice name that produces it (authoritative producer).
  let producerOf = Dict.make()
  slices->Array.forEach(s =>
    s.produced->Array.forEach(e =>
      switch producerOf->Dict.get(e.eventType) {
      | Some(_) => () // first producer wins; an event type is produced once
      | None => producerOf->Dict.set(e.eventType, s.sliceName)
      }
    )
  )

  // Rule 1 — partition(S) = producedKeys(S) \ foreignConsumedKeys(S), where a
  // foreign-consumed key rides a consumed arm produced by a *different* slice.
  let partitionBySlice = Dict.make()
  let ambiguities = []
  slices->Array.forEach(s => {
    let foreign = Set.make()
    s.consumed->Array.forEach(e =>
      switch producerOf->Dict.get(e.eventType) {
      | Some(producer) if producer != s.sliceName =>
        e->keysOfEvent->Array.forEach(k => foreign->Set.add(k))
      | _ => () // own-lifecycle read, or a producer not in this boundary
      }
    )
    let candidates = producedKeys(s)->Array.filter(k => !(foreign->Set.has(k)))
    switch candidates {
    | [single] => partitionBySlice->Dict.set(s.sliceName, single)
    | [] =>
      let _ = ambiguities->Array.push((
        s.sliceName,
        "no own partition key — every produced *Id is read from a foreign producer (pure join?); add an explicit @partitionTag",
      ))
    | many =>
      let _ = ambiguities->Array.push((
        s.sliceName,
        `multiple candidate partition keys (${many->Array.join(", ")}) — add an explicit @partitionTag`,
      ))
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
  // partition (and not this slice's own partition) is cross-partition.
  let crossKeys = Set.make()
  slices->Array.forEach(s => {
    let own = partitionBySlice->Dict.get(s.sliceName)
    s->consumedKeys->Array.forEach(k =>
      if ownedPartitionKeys->Set.has(k) && Some(k) != own {
        crossKeys->Set.add(k)
      }
    )
  })
  let crossPartitionTagKeys =
    Array.fromIterator(crossKeys->Set.values)->Array.toSorted((a, b) => String.compare(a, b))

  // Rule 3 — a produced event indexes only its producing slice's own partition
  // key; foreign reference keys are payload (omitted ⇒ no GSI write).
  let tagKeysByEventType = Dict.make()
  slices->Array.forEach(s => {
    let own = partitionBySlice->Dict.get(s.sliceName)
    s.produced->Array.forEach(e => {
      let indexed = e->keysOfEvent->Array.filter(k => Some(k) == own)
      tagKeysByEventType->Dict.set(e.eventType, dedupSorted(indexed))
    })
  })

  {partitionBySlice, ownerByKey, crossPartitionTagKeys, tagKeysByEventType, ambiguities}
}
