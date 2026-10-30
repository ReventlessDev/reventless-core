open ReventlessCore

// Plan 02 Phase 6b — unified Decision GWT DSL covering both Aggregate and
// StateChangeSlice. Two entry points:
//
//   * [Make(Spec, Decision)]              — StateChangeSlice form. [Spec] carries
//                                            [consumedEvent]; [Decision.evolve]
//                                            consumes it. DCB append-condition
//                                            checks are wired in.
//   * [MakeFromAggregate(Spec, Decision)] — Aggregate adapter. [Spec] is
//                                            [Reventless.Aggregate.Spec],
//                                            [Decision] is [Reventless.Decision.T].
//                                            No DCB semantics; the simpler
//                                            [AggregateT] surface is returned.
//
// Both produce the same [describe / test / givenEvents / whenCmd / then*]
// triple-A surface. Slice form additionally exposes
// [thenAppendsConditionedOn / thenAppendsConditionedOnExactly] for DCB
// optimistic-concurrency assertions.
//
// Aggregate users *cannot* use [Make] (their Spec doesn't carry [consumedEvent])
// and slice users *cannot* use [MakeFromAggregate] (their Spec/Decision shape
// differs). Pick the matching entry point.

// ---------------------------------------------------------------------------
// Who issues the command. `asCaller` names the caller before `whenCmd`; the
// command is then checked as production checks it: its `@authorize` rule against
// the caller's roles, then — for slices and aggregates that mark `@owner` on the
// events they decide on — against the owners the given events record, and for an
// aggregate owned by its id (`Id.Owned`) against the id `onId` names. Without
// `asCaller` the command carries no caller claim, which the handler reads as the
// platform acting for itself — so every scenario written before this existed is
// unchanged.
// ---------------------------------------------------------------------------
module Caller = {
  external unsafeAsString: 'a => string = "%identity"

  type t = {
    claim: Message.CallerClaim.t,
    /** The roles held, by name. A scenario names them by its plugin's own
        `Roles.t`, whose cases are their names at run time. */
    roles: array<Reventless.Role.name>,
    signedIn: bool,
  }

  // A plugin's roles are payload-less variants, strings at run time; anything
  // else would be compared with a rule's role names and never match.
  let roleNames = (roles: array<'role>): array<Reventless.Role.name> =>
    roles->Array.map(role =>
      if Reventless.OwnerScope.isJsString(role) {
        Reventless.Role.make(role->unsafeAsString)
      } else {
        JsError.throwWithMessage(
          "Caller: expected roles of the plugin's Roles.t (payload-less, so strings at runtime)",
        )
      }
    )

  /**
  A caller who owns only what records their id, holding `roles` (none by default).

  Takes the id as the scenario has it — `Caller.owner(c1)` with `c1: CustomerId.t`,
  or a plain string — because every `Id.Make` identity is a string on the wire.
  The type is not checked, and need not be: an id of the wrong entity matches no
  recorded owner, so it can only be refused, which fails the scenario that
  expected the owner to act. A value that is not a string at all is refused here.
  */
  let owner = (id: 'id, ~roles: array<'role>=[]): t =>
    if Reventless.OwnerScope.isJsString(id) {
      {claim: Owned({userId: id->unsafeAsString}), roles: roleNames(roles), signedIn: true}
    } else {
      JsError.throwWithMessage(
        "Caller.owner: expected an id (a string at runtime, such as an Id.Make identity)",
      )
    }

  /** A signed-in caller holding `roles`, who owns nothing the given events record. */
  let inRoles = (roles: array<'role>): t => {
    claim: Owned({userId: "caller-in-roles"}),
    roles: roleNames(roles),
    signedIn: true,
  }

  /** A caller exempt from ownership rules, acting on anyone's behalf. Holds no
      role: elevation does not grant a command whose rule the caller fails. */
  let operator: t = {claim: Exempt, roles: [], signedIn: true}
  /** An operator holding `roles`: a role the deployment elevates, such as an
      administrator acting on someone's behalf. */
  let operatorIn = (roles: array<'role>): t => {
    claim: Exempt,
    roles: roleNames(roles),
    signedIn: true,
  }
  /** A caller with no identity. */
  let anonymous: t = {claim: Unidentified, roles: [], signedIn: false}
}

/** `Caller` as a scenario sees it: roles typed by the spec's own `role`, so they
    are written bare (`Caller.inRoles([Merchandiser])`) and another plugin's role
    does not compile. */
module type Callers = {
  type role
  type t = Caller.t
  let owner: ('id, ~roles: array<role>=?) => t
  let inRoles: array<role> => t
  let operator: t
  let operatorIn: array<role> => t
  let anonymous: t
}

module Callers = (
  R: {
    type role
  },
): (Callers with type role = R.role) => {
  type role = R.role
  type t = Caller.t
  let owner = (id, ~roles: array<role>=[]) => Caller.owner(id, ~roles)
  let inRoles = (roles: array<role>) => Caller.inRoles(roles)
  let operator = Caller.operator
  let operatorIn = (roles: array<role>) => Caller.operatorIn(roles)
  let anonymous = Caller.anonymous
}

module type ActingSpec = {
  let name: string
  @schema
  type history
  @schema
  type command
  type role
  let authorizationOf: string => Reventless.Authorization.rule<role>
  // The aggregate's id is its owner (`Id.Owned`).
  let ownedById: bool
}

module Acting = (Spec: ActingSpec) => {
  let caller: ref<option<Caller.t>> = ref(None)
  // The aggregate the next command acts on, when the scenario names one.
  let streamId: ref<option<string>> = ref(None)
  let refusal: ref<option<CommandTopic_Helpers.rejectedResult>> = ref(None)

  let ownerFieldsByEventType = Reventless.Owner.fieldNamesByVariant(
    Spec.historySchema->S.castToUnknown,
  )

  let asCaller = (history, who: Caller.t) => {
    caller := Some(who)
    history
  }

  let onId = (history, id: string) => {
    streamId := Some(id)
    history
  }

  let commandName = command =>
    command->Message.encode(Spec.commandSchema)->Message.variantNameOfJson

  // The rule first, as production checks it, against the roles alone: which group
  // a role maps to is a deployment's fact, not the scenario's.
  let refusedByRule = (who: Caller.t, command: Spec.command): bool =>
    if (
      Spec.authorizationOf(commandName(command))
      ->Reventless.Authorization.named
      ->Reventless.Authorization.admits(~signedIn=who.signedIn, ~holds=role =>
        who.roles->Array.includes(role)
      )
    ) {
      false
    } else {
      refusal :=
        Some({
          errorCode: Reventless.CommandOutcome.code(Forbidden),
          errorDetail: `${Spec.name}.${commandName(
              command,
            )}: the caller holds no role this command's rule admits`,
        })
      true
    }

  // Every given event is the command's own history here, so all of them count.
  // The caller is consumed: the next scenario starts with no claim.
  let refuses = (history: array<Spec.history>, command: Spec.command): bool => {
    let who = caller.contents
    let id = streamId.contents
    caller := None
    streamId := None
    refusal := None
    let claim = who->Option.map(w => w.claim)
    if who->Option.mapOr(false, refusedByRule(_, command)) {
      true
    } else if ownerFieldsByEventType->Dict.keysToArray->Array.length == 0 && !Spec.ownedById {
      false
    } else {
      let owners = history->Array.reduce([], (owners, event) => {
        let (eventType, data) = event->Message.encode(Spec.historySchema)->Message.splitMessage
        switch ownerFieldsByEventType->Dict.get(eventType) {
        | Some(fields) => owners->Reventless.OwnerScope.recordOwners(~fields, data)
        | None => owners
        }
      })
      // An aggregate owned by its id, in a scenario that names none: the
      // partition cannot be named, as the handler would say.
      let recordedOwners = switch (Spec.ownedById, id) {
      | (false, _) => Some(owners)
      | (true, Some(id)) => Some(owners->Reventless.Owner.streamOwners(~ownedById=true, ~id))
      | (true, None) => None
      }
      refusal :=
        Reventless.OwnerScope.decideActing(~claim, ~recordedOwners)
        ->CommandTopic_Helpers.ownershipRefusal(~component=Spec.name, ~command=commandName(command))
        ->Option.map(r => r.rejected)
      refusal.contents->Option.isSome
    }
  }

  let encRefusal = (r: CommandTopic_Helpers.rejectedResult) =>
    JSON.Encode.object(
      Dict.fromArray([
        ("errorCode", JSON.Encode.string(r.errorCode)),
        ("errorDetail", JSON.Encode.string(r.errorDetail)),
      ]),
    )

  // Any other `then*` after a refused command fails: `decide` never ran, so
  // there is nothing for it to compare.
  let unexpectedRefusal = (): option<Outcome.outcome> =>
    refusal.contents->Option.map(r =>
      Outcome.fail(
        ErrorMismatch({expected: JSON.Encode.null, actual: Some(encRefusal(r)), actualEvents: []}),
      )
    )

  let thenForbidden = (~encEvents, ~decided: option<JSON.t>, events) =>
    switch refusal.contents {
    | Some(_) => Outcome.pass
    | None =>
      Outcome.fail(
        ErrorMismatch({
          expected: JSON.Encode.object(
            Dict.fromArray([
              ("errorCode", JSON.Encode.string(Reventless.CommandOutcome.code(Forbidden))),
            ]),
          ),
          actual: decided,
          actualEvents: encEvents(events),
        }),
      )
    }
}

// ---------------------------------------------------------------------------
// Slice form — replaces the legacy `StateChangeSlice_GWT`.
// ---------------------------------------------------------------------------

module type DecisionSpec = {
  let name: string

  @schema
  type consumedEvent

  @schema
  type command

  @schema
  type error

  @schema
  type event

  type role
  let authorizationOf: string => Reventless.Authorization.rule<role>
}

module type Decision = {
  module Spec: DecisionSpec

  type state
  let initialState: state
  let evolve: (state, Spec.consumedEvent) => state
  let decide: (state, Spec.command) => result<array<Spec.event>, Spec.error>
}

module type T = {
  module Spec: DecisionSpec

  let describe: (string, unit => unit) => unit
  let todo: string => unit
  let test: (string, unit => Outcome.outcome) => unit

  let givenEvents: array<Spec.consumedEvent> => array<Spec.consumedEvent>

  // Who issues the next `whenCmd`; see `Caller`.
  module Caller: Callers with type role = Spec.role
  let asCaller: (array<Spec.consumedEvent>, Caller.t) => array<Spec.consumedEvent>

  let whenCmd: (array<Spec.consumedEvent>, Spec.command) => array<Spec.event>

  let thenEvent: (array<Spec.event>, Spec.event) => Outcome.outcome
  let thenEvents: (array<Spec.event>, array<Spec.event>) => Outcome.outcome
  let thenNoEvent: array<Spec.event> => Outcome.outcome
  let thenEventWithError: (array<Spec.event>, Spec.event, Spec.error) => Outcome.outcome
  let thenEventsWithError: (array<Spec.event>, array<Spec.event>, Spec.error) => Outcome.outcome
  let thenError: (array<Spec.event>, Spec.error) => Outcome.outcome
  // Refused before `decide`: by the command's rule, or because the caller does not
  // own what it acts on.
  let thenForbidden: array<Spec.event> => Outcome.outcome

  // DCB optimistic-concurrency assertions.
  let thenAppendsConditionedOn: (array<Spec.event>, Reventless.DcbTag.query) => Outcome.outcome
  let thenAppendsConditionedOnExactly: (
    array<Spec.event>,
    Reventless.DcbTag.appendCondition,
  ) => Outcome.outcome
}

// JSON encoder for [Reventless.DcbTag.appendCondition]. The framework
// doesn't ship a sury schema for it; encoding structurally keeps the
// Outcome algebra's JSON payload closed.
let encodeTag = (t: Reventless.DcbTag.tag): JSON.t => {
  let d = Dict.make()
  d->Dict.set("key", JSON.Encode.string(t.key))
  d->Dict.set("value", JSON.Encode.string(t.value))
  JSON.Encode.object(d)
}

let encodeQueryItem = (qi: Reventless.DcbTag.queryItem): JSON.t => {
  let d = Dict.make()
  switch qi.eventTypes {
  | Some(types) =>
    d->Dict.set("eventTypes", types->Array.map(JSON.Encode.string)->JSON.Encode.array)
  | None => ()
  }
  switch qi.tags {
  | Some(tags) => d->Dict.set("tags", tags->Array.map(encodeTag)->JSON.Encode.array)
  | None => ()
  }
  JSON.Encode.object(d)
}

let encodeQuery = (q: Reventless.DcbTag.query): JSON.t =>
  q->Array.map(encodeQueryItem)->JSON.Encode.array

let encodeAppendCondition = (c: Reventless.DcbTag.appendCondition): JSON.t => {
  let d = Dict.make()
  d->Dict.set("query", encodeQuery(c.query))
  switch c.after {
  | Some(pos) => d->Dict.set("after", JSON.Encode.string(pos))
  | None => ()
  }
  JSON.Encode.object(d)
}

// ---------------------------------------------------------------------------
// Shared assertion core for both Decision GWT flavours.
//
// `Make` (slice/DCB) and `MakeFromAggregate` encode produced events / errors
// identically and compare them against the expectation the same way — only the
// DCB append-condition footgun that `Make` layers on top, and the `thenCompare*`
// custom-equality arms the aggregate flavour adds, differ. Factoring the
// comparison core out (mirroring `Delegate_GWT`'s `Make`) keeps the two from
// silently drifting. The `errors` ref is owned here and set by each outer
// functor's `exec`.
// ---------------------------------------------------------------------------
module type CoreSpec = {
  @schema
  type event
  @schema
  type error
}

module AssertionCore = (Spec: CoreSpec) => {
  let errors: ref<array<Spec.error>> = ref([])

  let encEvent = (e: Spec.event) => e->Message.encode(Spec.eventSchema)
  let encEvents = evs => evs->Array.map(encEvent)
  let encError = (err: Spec.error) => err->Message.encode(Spec.errorSchema)

  let unexpectedError = (events: array<Spec.event>): Outcome.outcome => {
    let actual = errors.contents->Array.get(0)->Option.map(encError)
    Outcome.fail(
      ErrorMismatch({
        expected: JSON.Encode.null,
        actual,
        actualEvents: events->encEvents,
      }),
    )
  }

  // Events are compared by their **encoded (wire) form**, not by ReScript
  // structural equality. For an event-sourced system the serialized event *is*
  // its identity: two events that reverse-convert to the same JSON are the same
  // event. Raw `==` is stricter than that — it distinguishes an optional field
  // that is present-but-`undefined` (what a decider's `deliveryWindow: ?x`
  // passthrough emits when `x` is `None`) from one whose key is absent (what a
  // test literal that omits the field produces), even though sury drops a `None`
  // optional either way and both hit the log identically. Comparing on `encEvents`
  // unifies that spurious difference, so an optional event field can be omitted in
  // the expectation instead of spelled out as `?None`. It is a strictly weaker
  // equality: equal values still encode equally, so nothing that passed can start
  // failing — it only stops the wire-invisible key asymmetry from failing a test.
  let compareEvents = (events, expectedEvents) =>
    if errors.contents->Array.length > 0 {
      unexpectedError(events)
    } else if events->encEvents == expectedEvents->encEvents {
      Outcome.pass
    } else {
      Outcome.fail(EventsMismatch({expected: expectedEvents->encEvents, actual: events->encEvents}))
    }

  let compareEventsWith = (events, expectedEvents, cmp) =>
    if errors.contents->Array.length > 0 {
      unexpectedError(events)
    } else if (
      events->Array.length == expectedEvents->Array.length &&
        Array.zip(events, expectedEvents)->Array.every(((e1, e2)) => cmp(e1, e2))
    ) {
      Outcome.pass
    } else {
      Outcome.fail(EventsMismatch({expected: expectedEvents->encEvents, actual: events->encEvents}))
    }

  let compareNoEvent = events =>
    if errors.contents->Array.length > 0 {
      unexpectedError(events)
    } else if events->Array.length == 0 {
      Outcome.pass
    } else {
      Outcome.fail(NoEventExpected({actual: events->encEvents}))
    }

  let matchesError = (
    events: array<Spec.event>,
    expectedEvents: array<Spec.event>,
    expectedError: Spec.error,
  ): Outcome.outcome => {
    let expectedErrorJson = encError(expectedError)
    switch errors.contents->Array.get(0) {
    | None =>
      Outcome.fail(
        ErrorMismatch({
          expected: expectedErrorJson,
          actual: None,
          actualEvents: events->encEvents,
        }),
      )
    | Some(actual) if actual != expectedError =>
      Outcome.fail(
        ErrorMismatch({
          expected: expectedErrorJson,
          actual: Some(encError(actual)),
          actualEvents: events->encEvents,
        }),
      )
    | Some(_) =>
      // Encoded comparison, for the same reason as `compareEvents` above.
      if events->encEvents == expectedEvents->encEvents {
        Outcome.pass
      } else {
        Outcome.fail(
          EventsMismatch({expected: expectedEvents->encEvents, actual: events->encEvents}),
        )
      }
    }
  }
}

module Make = (Spec: DecisionSpec, Decision: Decision with module Spec := Spec): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  let describe = JestBind.describe
  let todo = JestBind.todo
  let test = (name, body) =>
    JestBind.test(~slice=Spec.name, name, () =>
      ScenarioRecorder.around(~spec=Spec.name, name, body)
    )

  let currentState = consumed => consumed->Array.reduce(Decision.initialState, Decision.evolve)

  module Core = AssertionCore(Spec)
  let errors = Core.errors

  module Caller = Callers({
    type role = Spec.role
  })
  module Guard = Acting({
    let name = Spec.name
    type history = Spec.consumedEvent
    let historySchema = Spec.consumedEventSchema
    type command = Spec.command
    let commandSchema = Spec.commandSchema
    type role = Spec.role
    let authorizationOf = Spec.authorizationOf
    let ownedById = false
  })
  let asCaller = Guard.asCaller

  // DCB append-condition derived inside [whenCmd]; [None] until first call.
  let derivedCondition: ref<option<Reventless.DcbTag.appendCondition>> = ref(None)

  // Implicit pending failure raised when the derived query carries zero tags
  // across every clause AND the slice consumes at least one event type — a
  // strong signal that a [@s.matches(DcbTag.string)] annotation is missing
  // from the command schema. Regular [then*] combinators surface it before
  // their own checks; [thenAppends*] bypass it.
  let appendConditionFailure: ref<option<Outcome.mismatch>> = ref(None)

  let consumedEventTypes = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema).eventTypes

  // Scope derived from this slice's schemas, mirroring the StateChangeSlice runtime.
  let scopeShape = Reventless.DcbTag.sliceShapeFromSchemas(
    ~name="",
    ~commandSchema=Spec.commandSchema,
    ~consumedEventSchema=Spec.consumedEventSchema,
    ~eventSchema=Spec.eventSchema,
  )
  // Cross-partition tag keys fan a foreign-entity reference into its own single-tag
  // clause instead of being AND-ed with the partition. Unioned: any explicit
  // `@crossPartition` annotation (capacity / escape-hatch reads) plus the per-slice
  // inference (a foreign consumed key that is not this slice's partition), so a slice
  // with *no* annotation still reads correctly.
  let crossPartitionTagKeys = {
    let set = Set.make()
    Reventless.DcbTag.extractCrossPartitionTagKeys(Spec.eventSchema)->Array.forEach(k =>
      set->Set.add(k)
    )
    Reventless.DcbScopeInference.crossPartitionForSlice(scopeShape)->Array.forEach(k =>
      set->Set.add(k)
    )
    Array.fromIterator(set->Set.values)->Array.toSorted((a, b) => String.compare(a, b))
  }
  // Per-event indexed-tag map so a foreign reference key on this slice's *own*
  // emitted event (payload, not a read key) is narrowed out of a cross-partition
  // clause — the same dead-clause removal the runtime threads.
  let tagKeysByEventType = Reventless.DcbScopeInference.infer([scopeShape]).tagKeysByEventType
  // Command keys this slice does not decide by stay out of the query (rule 4),
  // judged against the partition the slice resolves to on its own.
  let payloadTagKeys = scopeShape->Reventless.DcbTag.commandPayloadTagKeys(
    ~partitionTag=Reventless.DcbScopeInference.resolvePartitions([scopeShape]).partitionBySlice
    ->Dict.get("")
    ->Option.map(key => Reventless.DcbTag.Simple({key: key})),
    ~crossPartitionTagKeys,
  )

  // Reachability guard inputs. The event types this slice *emits* are its own
  // history — read with composite AND clauses, which is fine. A *foreign* event
  // type (consumed from a sibling slice) is a cross-entity read: if the command
  // filters it by a tag key that appears in the decision query, yet the event
  // cannot satisfy any whole clause, it can never reach `decide` — the classic
  // "forgot @crossPartition on a cross-entity reference" bug (the key is AND-ed
  // with the partition instead of fanning into its own clause). Tag keys the
  // event carries but the command does NOT query are payload, not read keys, so
  // they are ignored (e.g. CancelOrder reads OrderPlaced by orderId and merely
  // carries its productIds over to the cancel event). Flow_GWT catches this
  // because it threads a real tagged log; this lets the per-slice GWT catch it
  // too, rather than folding an unreachable event straight through.
  let emittedEventTypes = Reventless.DcbDecode.makeDecoder(Spec.eventSchema).eventTypes
  let consumedTagKeysByType = Reventless.DcbTag.extractTagKeysByEventType(Spec.consumedEventSchema)

  let queryTagKeys = (query: Reventless.DcbTag.query): array<string> =>
    query->Array.flatMap(qi => qi.tags->Option.mapOr([], tags => tags->Array.map(t => t.key)))

  // True when some clause's tags are all carried by `declaredKeys` (so an event
  // declaring exactly those keys would match it). An empty query selects all.
  let selectableBy = (query: Reventless.DcbTag.query, declaredKeys: array<string>): bool =>
    query->Array.length == 0 ||
      query->Array.some(qi =>
        switch qi.tags {
        | None | Some([]) => true
        | Some(tags) => tags->Array.every(t => declaredKeys->Array.includes(t.key))
        }
      )

  // Foreign consumed event types the command filters by a query key yet cannot
  // select. Returns (eventType, offendingKey).
  let unreachableForeignReads = (query: Reventless.DcbTag.query): array<(string, string)> => {
    let qKeys = queryTagKeys(query)
    consumedTagKeysByType
    ->Dict.toArray
    ->Array.filterMap(((evType, keys)) =>
      switch keys->Array.find(k => qKeys->Array.includes(k)) {
      | Some(key) if !(emittedEventTypes->Array.includes(evType)) && !selectableBy(query, keys) =>
        Some((evType, key))
      | _ => None
      }
    )
  }

  let queryTagsTotal = (q: Reventless.DcbTag.query): int =>
    q->Array.reduce(0, (acc, qi) => acc + qi.tags->Option.mapOr(0, t => t->Array.length))

  let exec = (history, command): array<Spec.event> => {
    errors := []
    appendConditionFailure := None

    let query = Reventless.DcbTag.buildQueryFromCommand(
      ~eventTypes=consumedEventTypes,
      ~schema=Spec.commandSchema,
      ~value=command,
      ~tagKeysByEventType,
      ~crossPartitionTagKeys,
      ~payloadTagKeys,
    )
    let condition: Reventless.DcbTag.appendCondition = {query: query}
    derivedCondition := Some(condition)

    if consumedEventTypes->Array.length > 0 && queryTagsTotal(query) == 0 {
      appendConditionFailure :=
        Some(
          Outcome.AppendConditionMismatch({
            expected: JSON.Encode.string(
              "a non-empty tag set derived from @s.matches(DcbTag.string) fields on the command",
            ),
            actual: encodeAppendCondition(condition),
          }),
        )
    } else {
      // Surfaced through the same pending-failure channel as the zero-tags
      // footgun above (regular `then*` combinators check it first).
      switch unreachableForeignReads(query)->Array.get(0) {
      | Some((evType, key)) =>
        appendConditionFailure :=
          Some(
            Outcome.AppendConditionMismatch({
              expected: JSON.Encode.string(
                `a decision-query clause that selects '${evType}' on tag '${key}' alone — this is a cross-entity read, so mark '${key}' @crossPartition (or model it as a tagged array) and it will fan into its own clause; otherwise the decision model can never see '${evType}'`,
              ),
              actual: encodeAppendCondition(condition),
            }),
          )
      | None => ()
      }
    }

    if Guard.refuses(history, command) {
      []
    } else {
      switch Decision.decide(currentState(history), command) {
      | Ok(events) => events
      | Error(error) =>
        errors := [error]
        []
      }
    }
  }

  let givenEvents = consumed => consumed
  let whenCmd = (history, cmd) => {
    if ScenarioRecorder.recording() {
      ScenarioRecorder.given(
        history->Array.map(e =>
          e->Message.encode(Spec.consumedEventSchema)->Message.variantNameOfJson
        ),
      )
      ScenarioRecorder.whenCommand(Guard.commandName(cmd))
    }
    history->exec(cmd)
  }
  // What a test expects, named for the recorded sidecar.
  let expects = (~events=[], ~error=?) =>
    if ScenarioRecorder.recording() {
      ScenarioRecorder.thenEvents(
        events->Array.map(e => e->Core.encEvent->Message.variantNameOfJson),
      )
      error->Option.forEach(err =>
        ScenarioRecorder.thenError(err->Core.encError->Message.variantNameOfJson)
      )
    }

  let checkAppendCondition = (): option<Outcome.outcome> =>
    switch appendConditionFailure.contents {
    | Some(m) => Some(Outcome.fail(m))
    | None => Guard.unexpectedRefusal()
    }

  let thenForbidden = events =>
    Guard.thenForbidden(
      ~encEvents=Core.encEvents,
      ~decided=errors.contents->Array.get(0)->Option.map(Core.encError),
      events,
    )

  // The append-condition footgun is surfaced before the shared comparison core
  // runs; `thenAppends*` below bypass it deliberately.
  let thenEvents = (events, expectedEvents) => {
    expects(~events=expectedEvents)
    switch checkAppendCondition() {
    | Some(o) => o
    | None => Core.compareEvents(events, expectedEvents)
    }
  }

  let thenEvent = (events, expectedEvent) => thenEvents(events, [expectedEvent])

  let thenNoEvent = events => {
    if ScenarioRecorder.recording() {
      ScenarioRecorder.thenNoEvent()
    }
    switch checkAppendCondition() {
    | Some(o) => o
    | None => Core.compareNoEvent(events)
    }
  }

  let thenError = (events, expectedError) => {
    expects(~error=expectedError)
    switch checkAppendCondition() {
    | Some(o) => o
    | None => Core.matchesError(events, [], expectedError)
    }
  }

  let thenEventWithError = (events, expectedEvent, expectedError) => {
    expects(~events=[expectedEvent], ~error=expectedError)
    switch checkAppendCondition() {
    | Some(o) => o
    | None => Core.matchesError(events, [expectedEvent], expectedError)
    }
  }

  let thenEventsWithError = (events, expectedEvents, expectedError) => {
    expects(~events=expectedEvents, ~error=expectedError)
    switch checkAppendCondition() {
    | Some(o) => o
    | None => Core.matchesError(events, expectedEvents, expectedError)
    }
  }

  let thenAppendsConditionedOn = (_events, expectedQuery: Reventless.DcbTag.query) =>
    switch derivedCondition.contents {
    | None =>
      Outcome.fail(
        Throw({
          error: "thenAppendsConditionedOn: whenCmd must be called before this assertion",
          stack: "",
        }),
      )
    | Some(cond) =>
      if cond.query == expectedQuery {
        Outcome.pass
      } else {
        Outcome.fail(
          AppendConditionMismatch({
            expected: encodeAppendCondition({query: expectedQuery}),
            actual: encodeAppendCondition(cond),
          }),
        )
      }
    }

  let thenAppendsConditionedOnExactly = (
    _events,
    expectedCondition: Reventless.DcbTag.appendCondition,
  ) =>
    switch derivedCondition.contents {
    | None =>
      Outcome.fail(
        Throw({
          error: "thenAppendsConditionedOnExactly: whenCmd must be called before this assertion",
          stack: "",
        }),
      )
    | Some(cond) =>
      if cond == expectedCondition {
        Outcome.pass
      } else {
        Outcome.fail(
          AppendConditionMismatch({
            expected: encodeAppendCondition(expectedCondition),
            actual: encodeAppendCondition(cond),
          }),
        )
      }
    }
}

// ---------------------------------------------------------------------------
// Aggregate adapter — preserves the legacy Aggregate-flavor surface.
// ---------------------------------------------------------------------------

// Minimal aggregate spec the DSL requires. Declared inline (rather than
// aliasing `Reventless.Decision.T`'s inner Spec) because that inner Spec
// only carries the three @schema types — no `name` — and ReScript's
// `with module Spec = X` can only equate the inner Spec to a concrete
// module, not constrain it to a module type that adds `name`.
// What a step that only decides needs of an aggregate; `AggregateSpec` adds the id.
module type AggregateDeciderSpec = {
  let name: string
  @schema
  type command
  @schema
  type event
  @schema
  type error
  type role
  let authorizationOf: string => Reventless.Authorization.rule<role>
}

module type AggregateSpec = {
  module Id: Reventless.Id.T
  include AggregateDeciderSpec
}

module type AggregateT = {
  module Spec: AggregateSpec

  let describe: (string, unit => unit) => unit
  let todo: string => unit
  let test: (string, unit => Outcome.outcome) => unit

  let givenEvents: array<Spec.event> => array<Spec.event>

  // Who issues the next `whenCmd`; see `Caller`.
  module Caller: Callers with type role = Spec.role
  let asCaller: (array<Spec.event>, Caller.t) => array<Spec.event>
  // Which aggregate the next `whenCmd` acts on. Matters only where the id is the
  // owner (`Id.Owned`): there an owner's command on no named id is refused.
  let onId: (array<Spec.event>, Spec.Id.t) => array<Spec.event>

  let whenCmd: (array<Spec.event>, Spec.command) => array<Spec.event>

  let thenEvent: (array<Spec.event>, Spec.event) => Outcome.outcome
  let thenCompareEvent: (
    array<Spec.event>,
    Spec.event,
    (Spec.event, Spec.event) => bool,
  ) => Outcome.outcome
  let thenNoEvent: array<Spec.event> => Outcome.outcome
  let thenEventWithError: (array<Spec.event>, Spec.event, Spec.error) => Outcome.outcome
  let thenEvents: (array<Spec.event>, array<Spec.event>) => Outcome.outcome
  let thenCompareEvents: (
    array<Spec.event>,
    array<Spec.event>,
    (Spec.event, Spec.event) => bool,
  ) => Outcome.outcome
  let thenEventsWithError: (array<Spec.event>, array<Spec.event>, Spec.error) => Outcome.outcome
  let thenError: (array<Spec.event>, Spec.error) => Outcome.outcome
  // Refused before `decide`: by the command's rule, or because the caller does not
  // own what it acts on.
  let thenForbidden: array<Spec.event> => Outcome.outcome
}

module MakeFromAggregate = (Spec: AggregateSpec, Decision: Decision.T with module Spec = Spec): (
  AggregateT with module Spec = Spec
) => {
  module Spec = Spec

  let describe = JestBind.describe
  let todo = JestBind.todo
  let test = (name, body) =>
    JestBind.test(~slice=Spec.name, name, () =>
      ScenarioRecorder.around(~spec=Spec.name, name, body)
    )

  let currentState = events => events->Array.reduce(Decision.initialState, Decision.evolve)

  module Core = AssertionCore(Spec)
  let errors = Core.errors

  module Caller = Callers({
    type role = Spec.role
  })
  module Guard = Acting({
    let name = Spec.name
    type history = Spec.event
    let historySchema = Spec.eventSchema
    type command = Spec.command
    let commandSchema = Spec.commandSchema
    type role = Spec.role
    let authorizationOf = Spec.authorizationOf
    let ownedById = Reventless.Owner.isOwnedById(Spec.Id.schema)
  })
  let asCaller = Guard.asCaller
  let onId = (history, id) => history->Guard.onId(id->Spec.Id.toString)

  let exec = (history, command): array<Spec.event> => {
    errors := []
    if Guard.refuses(history, command) {
      []
    } else {
      switch Decision.decide(currentState(history), command) {
      | Ok(events) => events
      | Error(error) =>
        errors := [error]
        []
      }
    }
  }

  let givenEvents = events => events
  let whenCmd = (history, cmd) => {
    if ScenarioRecorder.recording() {
      ScenarioRecorder.given(history->Array.map(e => e->Core.encEvent->Message.variantNameOfJson))
      ScenarioRecorder.whenCommand(Guard.commandName(cmd))
    }
    history->exec(cmd)
  }
  // What a test expects, named for the recorded sidecar.
  let expects = (~events=[], ~error=?) =>
    if ScenarioRecorder.recording() {
      ScenarioRecorder.thenEvents(
        events->Array.map(e => e->Core.encEvent->Message.variantNameOfJson),
      )
      error->Option.forEach(err =>
        ScenarioRecorder.thenError(err->Core.encError->Message.variantNameOfJson)
      )
    }

  // The aggregate flavour has no append-condition footgun, so the shared core's
  // comparisons are exposed directly once a refusal has been ruled out; only
  // `thenCompare*` (custom equality) is specific to this surface.
  let unlessRefused = (events, compare) =>
    switch Guard.unexpectedRefusal() {
    | Some(o) => o
    | None => compare(events)
    }
  let thenEvents = (events, expected) => {
    expects(~events=expected)
    events->unlessRefused(Core.compareEvents(_, expected))
  }
  let thenCompareEvents = (events, expected, cmp) => {
    expects(~events=expected)
    events->unlessRefused(Core.compareEventsWith(_, expected, cmp))
  }
  let thenEvent = (events, expectedEvent) => thenEvents(events, [expectedEvent])
  let thenCompareEvent = (events, expectedEvent, cmp) =>
    thenCompareEvents(events, [expectedEvent], cmp)
  let thenNoEvent = events => {
    if ScenarioRecorder.recording() {
      ScenarioRecorder.thenNoEvent()
    }
    events->unlessRefused(Core.compareNoEvent)
  }

  let thenError = (events, expectedError) => {
    expects(~error=expectedError)
    events->unlessRefused(Core.matchesError(_, [], expectedError))
  }

  let thenEventWithError = (events, expectedEvent, expectedError) => {
    expects(~events=[expectedEvent], ~error=expectedError)
    events->unlessRefused(Core.matchesError(_, [expectedEvent], expectedError))
  }

  let thenEventsWithError = (events, expectedEvents, expectedError) => {
    expects(~events=expectedEvents, ~error=expectedError)
    events->unlessRefused(Core.matchesError(_, expectedEvents, expectedError))
  }

  let thenForbidden = events =>
    Guard.thenForbidden(
      ~encEvents=Core.encEvents,
      ~decided=errors.contents->Array.get(0)->Option.map(Core.encError),
      events,
    )
}
