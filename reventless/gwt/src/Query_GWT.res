// Stage 6 — query-pattern GWT for ReadModels and StateViewSlices.
//
// Where `MultiSourceProjection_GWT` (multi-source ReadModel) and `Projection_GWT`
// (single-source StateViewSlice) cover the projection *write*
// side (event → state actions), `Query_GWT` covers the read side: what queries
// must the projected state support? Indexes, sub-IDs, and GraphQL resolvers
// all exist to answer specific query patterns — none of which are derivable
// from the projection function alone.
//
// The DSL accepts the minimal intersection of `ReadModel.Spec` and
// `StateViewSlice.Spec` (`name`, `state`, `stateSchema`, `config`,
// `subIdConfig`), so both kinds of consumers use the same combinator set.
// Adapter functors `FromReadModel` and `FromStateViewSlice` lift their
// respective specs into the shared shape — mirroring how `Mapping_GWT` lifts
// `Aggregate.Spec`/`StateChangeSlice.Spec` via `FromBehavior`/`FromStateChangeSlice`.

// -- Unified spec shape ------------------------------------------------------

module type QueryableSpec = {
  let name: string

  @schema
  type state
  let stateSchema: S.t<state>

  let config: Reventless.ReadModel.config
  let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>>
}

module FromReadModel = (Spec: Reventless.ReadModel.Spec) => {
  let name = Spec.name
  type state = Spec.state
  let stateSchema = Spec.stateSchema
  let config = Spec.config
  let subIdConfig = Spec.subIdConfig
}

module FromStateViewSlice = (Spec: Reventless.StateViewSlice.Spec) => {
  let name = Spec.name
  type state = Spec.state
  let stateSchema = Spec.stateSchema
  let config = Spec.config
  let subIdConfig = Spec.subIdConfig
}

// -- Query argument shapes ---------------------------------------------------

type compositeId = {id: string, subId: string}

// A `whenQuery` scenario — `by` names the state field being filtered, `value`
// the expected value. `index` names a GSI when the field isn't the primary
// key. `filter` lets tests constrain the result set after the index lookup;
// `limit` truncates (used with `thenRowCount` for pagination).
type queryArgs<'state> = {
  by: string,
  value: string,
  index?: string,
  filter?: 'state => bool,
  limit?: int,
}

// -- Query_GWT DSL ----------------------------------------------------------

module type T = {
  module Spec: QueryableSpec

  let describe: (string, unit => unit) => unit
  let test: (string, unit => Outcome.outcome) => unit

  type store
  let givenStore: array<(string, Spec.state)> => store
  let givenCompositeStore: array<(string, string, Spec.state)> => store

  let whenQueryById: (store, string) => option<Spec.state>
  let whenQueryByCompositeId: (store, compositeId) => result<option<Spec.state>, Outcome.mismatch>
  let whenQuery: (store, queryArgs<Spec.state>) => result<array<Spec.state>, Outcome.mismatch>

  let thenRow: (option<Spec.state>, option<Spec.state>) => Outcome.outcome
  let thenRows: (result<array<Spec.state>, Outcome.mismatch>, array<Spec.state>) => Outcome.outcome
  let thenRowCount: (result<array<Spec.state>, Outcome.mismatch>, int) => Outcome.outcome
  let thenRowFromComposite: (
    result<option<Spec.state>, Outcome.mismatch>,
    option<Spec.state>,
  ) => Outcome.outcome
}

module Make = (Spec: QueryableSpec): (T with module Spec = Spec) => {
  module Spec = Spec


  let describe = JestBind.describe
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  type row = {id: string, subId: option<string>, state: Spec.state}
  type store = array<row>

  let encState = (s: Spec.state): JSON.t => s->Reventless.Util_Sury.toJson(Spec.stateSchema)
  let encStates = arr => arr->Array.map(encState)

  let givenStore = pairs =>
    pairs->Array.map(((id, state)) => {id, subId: None, state})

  let givenCompositeStore = triples =>
    triples->Array.map(((id, subId, state)) => {id, subId: Some(subId), state})

  // `whenQueryById` ignores `subId` — returns the first row with the given id.
  // Callers who want composite-id lookup go through `whenQueryByCompositeId`.
  let whenQueryById = (s: store, id) =>
    s->Array.findMap(r => if r.id == id {Some(r.state)} else {None})

  let whenQueryByCompositeId = (s: store, {id, subId}: compositeId): result<
    option<Spec.state>,
    Outcome.mismatch,
  > =>
    switch Spec.subIdConfig {
    | None =>
      Error(
        Outcome.QueryRowsMismatch({
          expected: [JSON.Encode.string(
            `composite-id lookup requires subIdConfig = Some({subIdField, getSubId}) in ${Spec.name}.config`,
          )],
          actual: [],
        }),
      )
    | Some(_) =>
      Ok(
        s->Array.findMap(r =>
          if r.id == id && r.subId == Some(subId) {
            Some(r.state)
          } else {
            None
          }
        ),
      )
    }

  // Does the schema declare an index with this name whose pk covers `field`?
  let indexCovers = (indexName: string, field: string): bool =>
    Spec.config.indexes->Array.some(idx =>
      idx.index == indexName &&
        (idx.idField == Some(field) ||
          switch idx.pkFields {
          | Some(fields) => fields->Array.includes(field)
          | None => false
          })
    )

  let whenQuery = (s: store, args: queryArgs<Spec.state>): result<
    array<Spec.state>,
    Outcome.mismatch,
  > => {
    // Config validation: if the caller named an `index`, verify the schema
    // actually declares it. Without this, the test could "pass" against an
    // in-memory store while the production config would reject the query.
    let indexError = switch args.index {
    | Some(name) if !indexCovers(name, args.by) =>
      Some(
        Outcome.QueryRowsMismatch({
          expected: [
            JSON.Encode.string(
              `index "${name}" covering field "${args.by}" is missing from ${Spec.name}.config.indexes`,
            ),
          ],
          actual: [],
        }),
      )
    | _ => None
    }

    switch indexError {
    | Some(err) => Error(err)
    | None =>
      let field = args.by
      let expected = args.value
      let matches = s->Array.filter(r => {
        let json = r.state->Reventless.Util_Sury.toJson(Spec.stateSchema)
        switch json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(field)) {
        | Some(v) =>
          let actualStr = switch v {
          | JSON.String(s) => s
          | JSON.Number(n) => n->Float.toString
          | JSON.Boolean(b) => b ? "true" : "false"
          | _ => v->JSON.stringify
          }
          actualStr == expected
        | None => false
        }
      })
      let afterFilter = switch args.filter {
      | Some(p) => matches->Array.filter(r => p(r.state))
      | None => matches
      }
      let afterLimit = switch args.limit {
      | Some(n) => afterFilter->Array.slice(~start=0, ~end=n)
      | None => afterFilter
      }
      Ok(afterLimit->Array.map(r => r.state))
    }
  }

  // -- Then combinators ----------------------------------------------------

  let thenRow = (actual: option<Spec.state>, expected: option<Spec.state>): Outcome.outcome =>
    if actual == expected {
      Outcome.pass
    } else {
      let actualJson = actual->Option.mapOr([], s => [encState(s)])
      let expectedJson = expected->Option.mapOr([], s => [encState(s)])
      Outcome.fail(QueryRowsMismatch({expected: expectedJson, actual: actualJson}))
    }

  let thenRows = (
    result: result<array<Spec.state>, Outcome.mismatch>,
    expected: array<Spec.state>,
  ): Outcome.outcome =>
    switch result {
    | Error(m) => Outcome.fail(m)
    | Ok(actual) =>
      if actual == expected {
        Outcome.pass
      } else {
        Outcome.fail(
          QueryRowsMismatch({expected: encStates(expected), actual: encStates(actual)}),
        )
      }
    }

  let thenRowCount = (
    result: result<array<Spec.state>, Outcome.mismatch>,
    expected: int,
  ): Outcome.outcome =>
    switch result {
    | Error(m) => Outcome.fail(m)
    | Ok(actual) =>
      if actual->Array.length == expected {
        Outcome.pass
      } else {
        Outcome.fail(
          QueryRowsMismatch({
            expected: [JSON.Encode.string(`row count = ${expected->Int.toString}`)],
            actual: [JSON.Encode.string(`row count = ${actual->Array.length->Int.toString}`)],
          }),
        )
      }
    }

  let thenRowFromComposite = (
    result: result<option<Spec.state>, Outcome.mismatch>,
    expected: option<Spec.state>,
  ): Outcome.outcome =>
    switch result {
    | Error(m) => Outcome.fail(m)
    | Ok(actual) => thenRow(actual, expected)
    }
}

// -- Cross-spec resolvers ----------------------------------------------------
//
// `@resolves` / `@resolvesMany` declare GraphQL resolvers that join a row in one
// read model to row(s) in a foreign table by a `*Id` / `*Ids` field. The
// single-spec `Make` above can't exercise these — the join target lives in a
// different spec. `MakeResolver(Primary, Target)` lifts both into one scenario:
// a primary store with the foreign-key field, a target store keyed by id, and
// `whenResolve` / `whenResolveMany` that follow the key across the boundary.
//
// The DSL validates that `Primary.config` actually declares the resolver for the
// field — so a test fails if the `@resolves` annotation is missing, exactly as
// `whenQuery` validates a named index.
module MakeResolver = (Primary: QueryableSpec, Target: QueryableSpec) => {

  let describe = JestBind.describe
  let sliceName = `${Primary.name}→${Target.name}`
  let test = (name, body) => JestBind.test(~slice=sliceName, name, body)

  type scenario = {
    primary: array<(string, Primary.state)>,
    target: array<(string, Target.state)>,
  }

  let givenStores = (primary, target): scenario => {primary, target}

  let encTarget = (s: Target.state): JSON.t => s->Reventless.Util_Sury.toJson(Target.stateSchema)
  let encTargets = arr => arr->Array.map(encTarget)

  let resolverFor = field =>
    Primary.config.idResolvers->Array.find(r => r.source.idField == field)
  let resolverManyFor = field =>
    Primary.config.idsResolvers->Array.find(r => r.source.idsField == field)

  let missing = msg =>
    Outcome.QueryRowsMismatch({expected: [JSON.Encode.string(msg)], actual: []})

  // Read a JSON field off the primary row's encoded state.
  let readField = (state: Primary.state, field): option<JSON.t> =>
    state
    ->Reventless.Util_Sury.toJson(Primary.stateSchema)
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get(field))

  let jsonToStr = v =>
    switch v {
    | JSON.String(s) => s
    | JSON.Number(n) => n->Float.toString
    | _ => v->JSON.stringify
    }

  let lookupTarget = (target, fkId) =>
    target->Array.findMap(((id, st)) => id == fkId ? Some(st) : None)

  let whenResolve = (scenario: scenario, ~field, primaryId): result<
    option<Target.state>,
    Outcome.mismatch,
  > =>
    switch resolverFor(field) {
    | None =>
      Error(missing(`@resolves on field "${field}" is missing from ${Primary.name}.config.idResolvers`))
    | Some(_) =>
      switch scenario.primary->Array.findMap(((id, st)) => id == primaryId ? Some(st) : None) {
      | None => Ok(None)
      | Some(pstate) =>
        switch readField(pstate, field) {
        | None => Ok(None)
        | Some(fk) => Ok(lookupTarget(scenario.target, jsonToStr(fk)))
        }
      }
    }

  let whenResolveMany = (scenario: scenario, ~field, primaryId): result<
    array<Target.state>,
    Outcome.mismatch,
  > =>
    switch resolverManyFor(field) {
    | None =>
      Error(
        missing(`@resolvesMany on field "${field}" is missing from ${Primary.name}.config.idsResolvers`),
      )
    | Some(_) =>
      switch scenario.primary->Array.findMap(((id, st)) => id == primaryId ? Some(st) : None) {
      | None => Ok([])
      | Some(pstate) =>
        switch readField(pstate, field) {
        | Some(JSON.Array(arr)) =>
          Ok(arr->Array.map(jsonToStr)->Array.filterMap(fkId => lookupTarget(scenario.target, fkId)))
        | _ => Ok([])
        }
      }
    }

  let thenResolved = (
    result: result<option<Target.state>, Outcome.mismatch>,
    expected: option<Target.state>,
  ): Outcome.outcome =>
    switch result {
    | Error(m) => Outcome.fail(m)
    | Ok(actual) =>
      actual == expected
        ? Outcome.pass
        : Outcome.fail(
            QueryRowsMismatch({
              expected: expected->Option.mapOr([], s => [encTarget(s)]),
              actual: actual->Option.mapOr([], s => [encTarget(s)]),
            }),
          )
    }

  let thenResolvedMany = (
    result: result<array<Target.state>, Outcome.mismatch>,
    expected: array<Target.state>,
  ): Outcome.outcome =>
    switch result {
    | Error(m) => Outcome.fail(m)
    | Ok(actual) =>
      actual == expected
        ? Outcome.pass
        : Outcome.fail(QueryRowsMismatch({expected: encTargets(expected), actual: encTargets(actual)}))
    }
}
