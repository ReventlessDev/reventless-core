// Local implementation of the live-update change descriptor — the JSON a
// subscriber receives on `/default/{listFieldName}/{entityKey}` after a read
// model row changes.
//
//   { changeKind, id, sortKeyValue?, seq, state? }
//
// One wire format, three independent implementations: this one (both local
// backends), the DynamoDB stream relay in `StateTopic_AppSync_Ops`, and the
// Postgres projection-side publisher in `StateTopicPublish.mjs`. They share no
// code — the relay's module is deliberately Pulumi-free so a core import can't
// drag deploy-time code into its Lambda graph. `StateChangeDescriptorParityTest`
// (reventless-aws) drives all three and asserts they agree.
//
// `state` is ADVISORY. A subscriber may always ignore it and refetch; that is
// what keeps the channel best-effort. A protocol that required the payload to be
// applied would have to be lossless, and this one is not — see
// `docs/analysis/live-update-descriptor-sequencing.md`.

/** Cap on the serialised state payload, in characters.
    AppSync Events caps a publish at ~240 KB, and the descriptor travels as a
    JSON string nested inside the publish body, so escaping inflates it. Counting
    characters rather than bytes keeps the rule identical across the three
    implementations without a UTF-8 length binding; the limit is set low enough
    that worst-case UTF-8 (3 bytes per character) plus escaping still fits.
    Over the cap the state is dropped and the downgrade logged — a metadata-only
    descriptor still tells the client to refetch, where a failed publish would
    tell it nothing. */
let maxStateChars = 60 * 1024

/** The `@retired` field of a registered read model, or `None`.

    Looked up by view name rather than passed down from the storage's
    construction, for the reason the resolvers look it up per request: a storage
    is built before every plugin's state schema is necessarily registered, and a
    lookup that missed at construction would publish payloads for the rest of
    the process. */
let retiredSpecFor = (name: string): option<Reventless.StateAnnotations.retiredSpec> =>
  ReventlessCore.Plugin_Helpers.stateSchemaRegistry
  ->Dict.get(name)
  ->Option.flatMap(Reventless.StateAnnotations.getSpec)
  ->Option.flatMap(spec => spec.retired)

let pickSortKeyValue = (state: JSON.t): option<string> =>
  switch state->JSON.Decode.object {
  | Some(obj) =>
    switch obj->Dict.get("updatedAt") {
    | Some(JSON.String(v)) => Some(v)
    | _ =>
      switch obj->Dict.get("createdAt") {
      | Some(JSON.String(v)) => Some(v)
      | _ => None
      }
    }
  | None => None
  }

// Monotonic ordering token. Seeded from the wall clock and never allowed to go
// backwards, so it keeps rising across process restarts — a client that held a
// value from a previous run won't reject everything the new run publishes.
//
// Monotonic, NOT consecutive: it is shared by every read model in the process,
// so one entity's values skip. That is deliberate — the DynamoDB relay reads its
// sequence off the stream record, which is equally sparse, and a dense counter
// would mean maintaining a version on every row (the analysis file has the cost).
// The client rule is "greater than what I hold", never "exactly one more".
let lastSequence = ref(0.0)

let nextSequence = (): string => {
  let now = Date.now()
  let next = now > lastSequence.contents ? now : lastSequence.contents +. 1.0
  lastSequence := next
  next->Float.toString
}

/** Build a state-change descriptor.
    - `changeKind`: one of "Added" | "Updated" | "Removed". save() emits "Added"
      when no visible row held the key and "Updated" otherwise; delete() emits
      "Removed".
    - `id`: entity key. Single-key projections: the partition-key value.
      Composite projections: `partition ++ "-" ++ subKey`.
    - `state`: the resulting row for save(); `None` for delete(), which has no new
      row — the descriptor then omits both `state` and `sortKeyValue`.
    - `seq`: monotonic ordering token, from `nextSequence`. */
let make = (
  ~changeKind: string,
  ~id: string,
  ~state: option<JSON.t>,
  ~seq: string,
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
): JSON.t => {
  let descriptor = Dict.make()
  descriptor->Dict.set("changeKind", JSON.Encode.string(changeKind))
  descriptor->Dict.set("id", JSON.Encode.string(id))
  // Whether the row this descriptor announces has been withdrawn from ordinary
  // reads. A publish cannot be scoped per subscriber — the channel is keyed by
  // list field and entity, and everyone watching the view receives it — so a
  // payload here would hand the row to exactly the callers the resolvers just
  // refused it to.
  // Both forms of `@retired` are the one question `isRetiredValue` answers, so
  // nothing here branches on which the view declared.
  let isRetired = switch (retiredField, state) {
  | (Some(field), Some(s)) =>
    {Reventless.OwnerScope.field, values: retiredValues}->Reventless.OwnerScope.isRetiredValue(
      s->JSON.Decode.object->Option.flatMap(d => d->Dict.get(field)),
    )
  | _ => false
  }
  // Dropped along with the payload, not just the payload: the sort value is a
  // timestamp off a row the subscriber may not read, and a subscriber without
  // one is conservative rather than wrong — it refetches instead of deciding
  // which page the row belongs on.
  switch isRetired ? None : state->Option.flatMap(pickSortKeyValue) {
  | Some(v) => descriptor->Dict.set("sortKeyValue", JSON.Encode.string(v))
  | None => ()
  }
  descriptor->Dict.set("seq", JSON.Encode.string(seq))
  switch state {
  // `Updated` with no payload is the shape this already emits for an oversized
  // row, and it means the same thing to a client: refetch and let the query
  // layer answer. Deliberately not `Removed` — the row is not gone, and saying
  // so would be false for an elevated subscriber reading with `includeRetired`
  // and false again the moment the row is restored.
  | Some(_) if isRetired => ()
  | Some(s) =>
    let encoded = s->JSON.stringify
    if encoded->String.length <= maxStateChars {
      descriptor->Dict.set("state", s)
    } else {
      Console.warn(
        `STATE_PAYLOAD_DOWNGRADED id=${id} chars=${encoded->String.length->Int.toString}`,
      )
    }
  | None => ()
  }
  descriptor->JSON.Encode.object
}
