// GraphQL query resolvers for in-memory QueryDb.
// Make(Bus) functor: registers query fields into the provided server during component construction.
// Supports: getById, list (when listFieldName provided), {name}ById (when subId), and {name}By{Index} per index.
//
// Query names are resolved from Plugin_Helpers.queryFieldNamesRegistry (populated by
// Plugin_Builder) to align with fragment SDL. Falls back to camelCase(name) for
// backward compatibility when no registry entry exists.
//
// Relay support is domain-only (platform QueryDbs pass relay=None):
//   - encodeGlobalId / decodeGlobalId for Relay global IDs
//   - node(id: ID!) resolution via registerNodeResolverCallback
//   - registerNodeType for the Relay Node type registry
// Platform admin views are not Relay-paginated so relay=None is correct for them.

// Relay support type — lifted to module level so Platform.res can construct a value
// without a functor application in type position (not supported in ReScript).
// Domain plugins pass Some(domainRelaySupport); platform plugins pass None.
type relaySupport = {
  encodeGlobalId: (~typeName: string, ~localId: string) => string,
  registerNodeType: (~typeName: string, ~queryDbName: string) => unit,
  registerNodeResolverCallback: DomainGraphQL_Server.nodeResolverCallback => unit,
  nodeTypeRegistry: ref<dict<string>>,
}

@val external btoa: string => string = "btoa"
@val external atob: string => string = "atob"

// Keyset-cursor helpers for the `{name}Items` (sub-id) connection — base64 of
// the sub-key value. The main connection list resolver's cursor logic now lives
// in `QueryDbListQuery`; these remain for the items resolver below.
let encodeCursor = (value: string): string => btoa(value)
let decodeCursor = (cursor: string): string => atob(cursor)

module Make = (Bus: LocalBus.T) => {
  open ReventlessCore

  type api = unit
  type role = unit

  // -- Identity extraction from GraphQL context ---------------------------------
  // graphql-yoga's `context` factory in DomainGraphQL_Server.buildAuthContext
  // runs LocalAuth.authenticate per request and attaches the resolved
  // `Identity.t` to `ctx.identity`. Fallback to anonymous only when ctx is
  // malformed.

  let extractIdentity = (ctx: JSON.t): Reventless.Identity.t => {
    try {
      switch (ctx->Obj.magic)["identity"]->Nullable.toOption {
      | Some(id) => (id: Reventless.Identity.t)
      | None => Reventless.Identity.anonymous
      }
    } catch {
    | _ => Reventless.Identity.anonymous
    }
  }

  // -- Module-level server and relay refs ------------------------------------
  // Set by Platform.res before component construction runs so the make function
  // can pick up the correct target server and relay support (mirrors AWS ~api pattern).
  let serverRef: ref<ReventlessGraphqlServer.GraphQL_ServerInstance.t> = ref(DomainGraphQL_Server.asInterface)
  let relayRef: ref<option<relaySupport>> = ref(Some({
    encodeGlobalId: DomainGraphQL_Server.encodeGlobalId,
    registerNodeType: DomainGraphQL_Server.registerNodeType,
    registerNodeResolverCallback: DomainGraphQL_Server.registerNodeResolverCallback,
    nodeTypeRegistry: DomainGraphQL_Server.nodeTypeRegistry,
  }))

  let make: QueryDb_Adapter.resolversMaker<unit, unit> = (
    ~name,
    ~api as _,
    ~apiRole as _,
    ~dataSourceName as _,
    ~indexes,
    ~subIdField,
    ~idResolverConfigs as _,
    ~idsResolverConfigs as _,
    ~authorization,
    ~opts as _,
  ) => {
    // Read the active server and relay support from module-level refs set by Platform.res.
    // This mirrors how AWS adapters receive ~api from the hook; here the hook sets the refs
    // before calling make() so the values are available at registration time.
    let server = serverRef.contents
    let relay = relayRef.contents

    // Register the Relay node resolver callback once per QueryDb (domain only).
    // Scans all QueryDb instances to resolve node(id: ID!) queries.
    // `node` is the one door that speaks Relay global ids, on both sides: it needs
    // the `<Type>:` prefix to know which read model to load, so a storage key alone
    // could not be resolved here. Every other door — the list, `X(id:)`,
    // `XsByIds`, `filter.ids` — reports the storage key, which is what a client
    // reads off a row and passes back. Callers that hold a global id are still
    // served by the typed doors (see `Api_Ids.alternateKey`); the reverse is not
    // possible, which is why this door is opt-in rather than the default form.
    switch relay {
    | Some(r) =>
      r.registerNodeResolverCallback(async (~typeName, ~localId) => {
        let queryDbName = switch r.nodeTypeRegistry.contents->Dict.get(typeName) {
        | Some(n) => n
        | None => typeName
        }
        switch Bus.getQueryDb(queryDbName) {
        | Some(ops) =>
          let items =
            await ops.loadStream(localId)
            ->Stream.runCollect
            ->Effect.catchAll(_ => Effect.succeed([]))
            ->Effect.runPromise
          switch items->Array.get(0) {
          | Some(item) =>
            // Copied: `JSON.Decode.object` hands back the stored object itself, so
            // setting a field here would rewrite the row inside the QueryDb — the
            // in-memory backend keeps the very object it returns.
            let obj = item->JSON.Decode.object->Option.mapOr(Dict.make(), Dict.copy)
            obj->Dict.set("__typename", JSON.Encode.string(typeName))
            obj->Dict.set("id", r.encodeGlobalId(~typeName, ~localId)->JSON.Encode.string)
            Some(JSON.Encode.object(obj))
          | None => None
          }
        | None => None
        }
      })
    | None => ()
    }

    let runInterceptor = async (~ctx, ~args): QueryDb_Callback.interceptResult => {
      let identity = extractIdentity(ctx)
      // Spec-level authorization runs first; failures short-circuit before
      // the user-supplied interceptor (mirrors mutation enforcement).
      if !Reventless.Authorization.isAllowed(authorization, identity) {
        Deny("Forbidden")
      } else {
        switch QueryDb_Callback.queryInterceptorHook.contents {
        | None => Allow
        | Some(interceptor) => await interceptor(~identity, ~readModelName=name, ~args)
        }
      }
    }

    // ── Owner scoping ────────────────────────────────────────────────────────
    // What a caller may see of a view whose state declares an `@owner` field.
    // Sits beside `runInterceptor` on purpose: these are the two questions every
    // door has to ask, and a door that forgets one of them is a hole rather than
    // a degradation. Answering "may they read this at all" and "which rows" in
    // the same place is what makes the omission visible when reading a resolver.
    // Read per request rather than captured at registration: a resolver is built
    // before every plugin's state schema is necessarily registered, and a lookup
    // that missed here would leave the view unscoped rather than erroring.
    let ownerFieldOf = () =>
      Plugin_Helpers.stateSchemaRegistry
      ->Dict.get(name)
      ->Option.flatMap(s => Reventless.Owner.fieldNames(s)->Array.get(0))

    // An owner-scoped view with no elevated groups configured scopes EVERYONE,
    // administrators included. That is the safe direction to be wrong in and it
    // is still wrong, and it is invisible from outside — an operator's empty list
    // looks exactly like an operator who owns nothing. Said once per view at
    // registration, because the alternative is finding out from a support ticket.
    OwnerScopeDiagnostics.warnIfNoElevatedGroups(
      ~comp="QueryDbResolvers_GraphQL",
      ~view=name,
      ~ownerField=ownerFieldOf(),
    )

    let ownerDecision = (~ctx) =>
      extractIdentity(ctx)->Reventless.OwnerScope.decide(~ownerField=ownerFieldOf())

    // Post-read form, for the single-row and by-index doors where there is no
    // page to narrow — the row is already in hand and either belongs to the
    // caller or does not.
    let ownerAllows = (~ctx, item: JSON.t) =>
      switch ownerDecision(~ctx) {
      | Unscoped => true
      | RefuseOwned => false
      | ScopeTo(field, required) =>
        item
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get(field))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.mapOr(false, v => v == required)
      }

    // ── Retirement narrowing ─────────────────────────────────────────────────
    // The same two forms as owner scoping above, for the same reason: a door
    // that narrows the page and a door that hands back one row both have to ask.
    // Read per request for the same reason too.
    let retiredSpecOf = () =>
      Plugin_Helpers.stateSchemaRegistry
      ->Dict.get(name)
      ->Option.flatMap(Reventless.StateAnnotations.getSpec)
      ->Option.flatMap(spec => spec.retired)

    // `includeRetired` is the caller asking; `decideRetired` decides whether the
    // asking counts. Read here rather than inside the decision so the argument
    // stays an argument — the door reports what was asked, the classifier says
    // who may be answered.
    let askedForRetired = (~args) =>
      args
      ->JSON.Decode.object
      ->Option.flatMap(d => d->Dict.get("includeRetired"))
      ->Option.flatMap(JSON.Decode.bool)
      ->Option.getOr(false)

    let retiredDecision = (~ctx, ~args) =>
      extractIdentity(ctx)->Reventless.OwnerScope.decideRetired(
        ~retiredField=retiredSpecOf()->Option.map(r => r.field),
        ~retiredValue=?retiredSpecOf()->Option.flatMap(r => r.value),
        ~asked=askedForRetired(~args),
      )

    let retiredScopeFor = (~ctx, ~args) =>
      retiredDecision(~ctx, ~args)->Reventless.OwnerScope.retiredScopeOf

    // Post-read form. The single-row and by-ids doors are where a filtered list
    // would otherwise be walked around: a pasted URL, or a reference resolved
    // from another row, reaches the entity directly.
    let retiredAllows = (~ctx, ~args, item: JSON.t) =>
      switch retiredScopeFor(~ctx, ~args) {
      | None => true
      // Absent keeps the row, matching `QueryDbListQuery`: a row written before
      // the annotation existed is not retired. Which of the two forms decides
      // that is `isRetiredValue`'s question, not this door's.
      | Some(scope) =>
        !(
          scope->Reventless.OwnerScope.isRetiredValue(
            item->JSON.Decode.object->Option.flatMap(d => d->Dict.get(scope.field)),
          )
        )
      }

    let cap = s => s->String.charAt(0)->String.toUpperCase ++ s->String.slice(~start=1)

    // Resolve query field names: check registry first, fall back to safe defaults.
    // Fallbacks use simple GraphQL built-in types to avoid referencing non-existent custom types.
    let registryEntry = Plugin_Helpers.queryFieldNamesRegistry->Dict.get(name)
    let singleQueryName = switch registryEntry {
    | Some({singleFieldName}) => singleFieldName
    | None => name->String.charAt(0)->String.toLowerCase ++ name->String.slice(~start=1)
    }
    let listQueryName = switch registryEntry {
    | Some({listFieldName}) => listFieldName
    | None => name ++ "s"
    }
    let returnTypeName = switch registryEntry {
    | Some({returnTypeName: rt}) => rt
    | None => "String"
    }
    let pluralTypeName = switch registryEntry {
    | Some({pluralTypeName}) => pluralTypeName
    | None => "[String]"
    }

    // Resolve includeIdParam flag from registry (defaults to true for ReadModels)
    let includeIdParam = switch registryEntry {
    | Some({includeIdParam}) => includeIdParam
    | None => true
    }

    // Resolve connectionSpec flag from registry (defaults to true)
    let connectionSpec = switch registryEntry {
    | Some({connectionSpec}) => connectionSpec
    | None => true
    }

    // Register this entity type in the Relay Node type registry (domain only).
    if includeIdParam {
      switch relay {
      | Some(r) => r.registerNodeType(~typeName=returnTypeName, ~queryDbName=name)
      | None => ()
      }
    }

    // -- Main query: getById ---------------------------------------------------
    let byIdSdl = if includeIdParam {
      switch subIdField {
      | Some(sf) => `  ${singleQueryName}(id: ID!, ${sf}: String): ${returnTypeName}`
      | None => `  ${singleQueryName}(id: ID!): ${returnTypeName}`
      }
    } else {
      `  ${singleQueryName}: ${returnTypeName}`
    }
    let byIdResolver: ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
      switch await runInterceptor(~ctx, ~args) {
      | Deny(_) => JSON.Encode.null
      | Allow =>
        let id =
          args->JSON.Decode.object->Option.flatMap(d => d->Dict.get("id"))->Option.flatMap(JSON.Decode.string)->Option.getOr("")
        switch Bus.getQueryDb(name) {
        | Some(ops) =>
          let load = key =>
            ops.loadStream(key)
            ->Stream.runCollect
            ->Effect.catchAll(_ => Effect.succeed([]))
            ->Effect.runPromise
          let firstAttempt = await load(id)
          // The row advertises a Relay global id, so `X(id: row.id)` arrives here
          // as one. Retried rather than decoded up front: the raw key is what this
          // door has always taken, and a key that merely looks like base64 must
          // keep resolving to its own row.
          let (resolvedKey, items) = switch (
            firstAttempt->Array.get(0),
            Api_Ids.alternateKey(id),
          ) {
          | (None, Some(localId)) => (localId, await load(localId))
          | _ => (id, firstAttempt)
          }
          switch items->Array.get(0) {
          // A row the caller does not own answers as though it were not there.
          // Distinguishing "not yours" from "not found" here would turn this door
          // into an oracle for which ids exist.
          | Some(item) if !ownerAllows(~ctx, item) || !retiredAllows(~ctx, ~args, item) =>
            JSON.Encode.null
          | Some(item) =>
            if includeIdParam {
              // Copied — `JSON.Decode.object` hands back the stored object itself,
              // so setting a field here would rewrite the row inside the QueryDb.
              let obj = item->JSON.Decode.object->Option.mapOr(Dict.make(), Dict.copy)
              // The storage key, which is what the list answers and what this door
              // takes back. `resolvedKey`, not the argument: a caller who passed a
              // Relay global id gets the raw key returned, so a round trip through
              // this door converges on the one form instead of alternating.
              obj->Dict.set("id", JSON.Encode.string(resolvedKey))
              JSON.Encode.object(obj)
            } else {
              item
            }
          | None => JSON.Encode.null
          }
        | None => JSON.Encode.null
        }
      }
    }

    // -- Batched-by-ids query: {listFieldName}ByIds ---------------------------
    // Mirrors the AppSync BatchGetItem resolver. Single-key projections only
    // (subIdField=None) — matches the SDL emitted by FragmentGenerator. Missing
    // ids drop out of the response (no cardinality preservation), matching
    // BatchGetItem semantics.
    let byIdsSdl = if includeIdParam && subIdField === None {
      [GraphQL_FragmentGenerator.deriveByIdsQueryField(~listFieldName=listQueryName, ~returnTypeName)]
    } else {
      []
    }
    let byIdsResolverEntry: option<(string, ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn)> =
      if includeIdParam && subIdField === None {
        let resolver: ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
          switch await runInterceptor(~ctx, ~args) {
          | Deny(_) => []->JSON.Encode.array
          | Allow =>
            let ids =
              args
              ->JSON.Decode.object
              ->Option.flatMap(d => d->Dict.get("ids"))
              ->Option.flatMap(JSON.Decode.array)
              ->Option.getOr([])
              ->Array.filterMap(JSON.Decode.string)
            switch Bus.getQueryDb(name) {
            | Some(ops) =>
              let load = key =>
                ops.loadStream(key)
                ->Stream.runCollect
                ->Effect.catchAll(_ => Effect.succeed([]))
                ->Effect.runPromise
              // Same either-form rule as the single-id door: raw key first, the
              // key inside a Relay global id only on a miss.
              let loaded = await ids->Array.map(async id =>
                switch (await load(id))->Array.get(0) {
                | Some(item) => (id, Some(item))
                | None =>
                  switch Api_Ids.alternateKey(id) {
                  | Some(localId) => (localId, (await load(localId))->Array.get(0))
                  | None => (id, None)
                  }
                }
              )->Promise.all
              loaded
              ->Array.filterMap(((id, opt)) =>
                opt
                ->Option.filter(item => ownerAllows(~ctx, item) && retiredAllows(~ctx, ~args, item))
                ->Option.map(item => {
                  let obj = item->JSON.Decode.object->Option.mapOr(Dict.make(), Dict.copy)
                  obj->Dict.set("id", JSON.Encode.string(id))
                  JSON.Encode.object(obj)
                })
              )
              ->JSON.Encode.array
            | None => []->JSON.Encode.array
            }
          }
        }
        Some((listQueryName ++ "ByIds", resolver))
      } else {
        None
      }

    // Look up labelField from registry (Phase 3). Used by list-query filter.search /
    // searchPrefix to target the entity's human-readable column without per-entity
    // resolver wiring. Falls back to "id" so filtering still works on entities
    // without a @displayName annotation (match on the partition key).
    let labelField = switch registryEntry {
    | Some({labelField: ?lf}) => lf->Option.getOr("id")
    | None => "id"
    }

    // -- List query -------------------------------------------------------------
    // Look up the registered state schema (populated alongside queryFieldNamesRegistry)
    // so the resolver derives the same serverCapability the FragmentGenerator emitted.
    let stateSchemaOpt = Plugin_Helpers.stateSchemaRegistry->Dict.get(name)
    let capability = switch stateSchemaOpt {
    | Some(s) => GraphQL_FragmentGenerator.deriveServerCapability(~entityName=name, s)
    | None => GraphQL_FragmentGenerator.emptyCapability
    }

    // Materialise the whole read model (stream preferred, scan fallback). The
    // fallback path for list queries when no backend push-down is available.
    let fetchAllItems = async (): array<JSON.t> =>
      switch Bus.getQueryDbStream(name) {
      | Some(makeStream) => await makeStream()->Stream.runCollect->Effect.runPromise
      | None =>
        switch Bus.getQueryDbScan(name) {
        | Some(scanAll) => scanAll()
        | None => []
        }
      }

    let (listSdl, listResolver): (array<string>, ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn) = if connectionSpec {
      // Relay Connection spec format
      let filterTypeName = returnTypeName ++ "Filter"
      let orderByTypes = GraphQL_FragmentGenerator.deriveConnectionOrderByType(
        ~singularTypeName=returnTypeName,
        ~capability,
      )
      let hasOrderBy = orderByTypes->Array.length > 0
      let typesToRegister = [
        GraphQL_FragmentGenerator.deriveConnectionFilterType(~filterTypeName, ~capability),
      ]->Array.concat(orderByTypes)
      server.registerTypes(~sdlTypes=typesToRegister)
      let sdl = [
        GraphQL_FragmentGenerator.deriveConnectionQueryField(
          ~listFieldName=listQueryName,
          ~singularTypeName=returnTypeName,
          ~filterTypeName,
          ~hasOrderBy,
        ),
      ]
      let emptyConnection = Obj.magic({
        "edges": [],
        "pageInfo": {
          "hasNextPage": false,
          "hasPreviousPage": false,
          "startCursor": Nullable.null,
          "endCursor": Nullable.null,
        },
      })
      let resolver: ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
        switch await runInterceptor(~ctx, ~args) {
        | Deny(_) => emptyConnection
        | Allow =>
          switch ownerDecision(~ctx) {
          | RefuseOwned => emptyConnection
          | decision =>
            let ownerScope = Reventless.OwnerScope.scopeOf(decision)
            // Same both-arms rule as `ownerScope`, and the same reason it is
            // spelled out: this predicate decides what the caller may see, so a
            // push-down that did not receive it would serve the archive to
            // everyone on the path that is hardest to notice.
            let retiredScope = retiredScopeFor(~ctx, ~args)
            let argsDict = args->JSON.Decode.object->Option.getOr(Dict.make())
            // Prefer a backend list push-down (SQLite builds json_extract predicates
            // + ORDER BY … LIMIT so it never materialises the whole read model). When
            // the backend can't serve this query shape it returns None and we fall
            // back to materialising the full model and running the shared
            // `QueryDbListQuery` spec over it (the same code the in-memory backend and
            // the push-down are tested against).
            //
            // `ownerScope` goes to BOTH arms. Passing it only to the fallback would
            // scope the exceptional path and leave the normal one — the push-down —
            // returning everything, which is the worst possible place for the gap
            // because the fallback is what the tests most easily exercise.
            let decodeLocalId = id =>
              DomainGraphQL_Server.decodeGlobalId(id)->Option.map(((_, lid)) => lid)
            switch Bus.getQueryDbListPage(name) {
            | Some(listPage) =>
              switch listPage(~argsDict, ~capability, ~labelField, ~ownerScope?, ~retiredScope?) {
              | Some(conn) => conn
              | None =>
                let items = await fetchAllItems()
                QueryDbListQuery.run(
                  ~items,
                  ~argsDict,
                  ~capability,
                  ~labelField,
                  ~decodeLocalId,
                  ~ownerScope?,
                  ~retiredScope?,
                )
              }
            | None =>
              let items = await fetchAllItems()
              QueryDbListQuery.run(
                ~items,
                ~argsDict,
                ~capability,
                ~labelField,
                ~decodeLocalId,
                ~ownerScope?,
                ~retiredScope?,
              )
            }
          }
        }
      }
      (sdl, resolver)
    } else {
      // Legacy AppSync-style format
      let sdl = [`  ${listQueryName}(nextToken: String, limit: Int): ${pluralTypeName}!`]
      let resolver: ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
        switch await runInterceptor(~ctx, ~args) {
        | Deny(_) => Obj.magic({"nextToken": Nullable.null, "scannedCount": 0, "items": []})
        | Allow =>
          let all = await fetchAllItems()
          // The legacy shape has no push-down to reach, so the narrowing is a plain
          // filter here. `scannedCount` counts what is returned, not what was read:
          // the pre-scoping total would tell a caller how many rows they may not see.
          let items =
            all->Array.filter(item => ownerAllows(~ctx, item) && retiredAllows(~ctx, ~args, item))
          Obj.magic({"nextToken": Nullable.null, "scannedCount": items->Array.length, "items": items})
        }
      }
      (sdl, resolver)
    }
    let listResolvers = [(listQueryName, listResolver)]

    // -- Items query: {name}Items (only when subId configured) -----------------
    // Relay Connection response. Accepts `filter` input object + first/after/last/before.
    // Cursor is base64 of the sort key value (keyset pagination — see module-level
    // `encodeCursor` / `decodeCursor` helpers).
    let itemsSdl = switch subIdField {
    | Some(_sf) =>
      let filterTypeName = returnTypeName ++ "ItemsFilter"
      let connectionTypeName = returnTypeName ++ "Connection"
      server.registerTypes(
        ~sdlTypes=[
          `input ${filterTypeName} {\n  prefix: String\n  from: String\n  to: String\n  eq: String\n  order: SortOrder\n}`,
        ],
      )
      [`  ${singleQueryName}Items(id: ID!, filter: ${filterTypeName}, first: Int, after: String, last: Int, before: String): ${connectionTypeName}!`]
    | None => []
    }
    let itemsResolvers: array<(string, ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn)> = switch subIdField {
    | Some(sf) =>
      let resolver: ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
        let emptyConn = Obj.magic({
          "edges": [],
          "pageInfo": {
            "hasNextPage": false,
            "hasPreviousPage": false,
            "startCursor": Nullable.null,
            "endCursor": Nullable.null,
          },
        })
        switch await runInterceptor(~ctx, ~args) {
        | Deny(_) => emptyConn
        | Allow =>
          let argsDict = args->JSON.Decode.object->Option.getOr(Dict.make())
          let id = argsDict->Dict.get("id")->Option.flatMap(JSON.Decode.string)->Option.getOr("")
          let filterDict =
            argsDict->Dict.get("filter")->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
          let filterPrefix = filterDict->Dict.get("prefix")->Option.flatMap(JSON.Decode.string)
          let filterFrom   = filterDict->Dict.get("from")->Option.flatMap(JSON.Decode.string)
          let filterTo     = filterDict->Dict.get("to")->Option.flatMap(JSON.Decode.string)
          let filterEq     = filterDict->Dict.get("eq")->Option.flatMap(JSON.Decode.string)
          let orderDesc    = filterDict->Dict.get("order")->Option.flatMap(JSON.Decode.string)->Option.map(o => o == "DESC")->Option.getOr(false)
          let first        = argsDict->Dict.get("first")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
          let after        = argsDict->Dict.get("after")->Option.flatMap(JSON.Decode.string)
          let last         = argsDict->Dict.get("last")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
          let before       = argsDict->Dict.get("before")->Option.flatMap(JSON.Decode.string)
          let isBackward   = last->Option.isSome

          switch Bus.getQueryDb(name) {
          | None => emptyConn
          | Some(ops) =>
            let loaded =
              await ops.loadStream(id)
              ->Stream.runCollect
              ->Effect.catchAll(_ => Effect.succeed([]))
              ->Effect.runPromise
            // Narrowed here, before the cursor window and the sort-key filter, so
            // every page this door emits is a page of rows the caller owns. Doing
            // it after would hand back short pages with valid cursors.
            let allItems =
              loaded->Array.filter(item =>
                ownerAllows(~ctx, item) && retiredAllows(~ctx, ~args, item)
              )

            // Cursor-keyed filtering: exclude items on the cursor side of the boundary
            let cursorFiltered = if isBackward {
              switch before->Option.map(decodeCursor) {
              | Some(beforeKey) =>
                allItems->Array.filter(item =>
                  item->JSON.Decode.object->Option.flatMap(d => d->Dict.get(sf))->Option.flatMap(JSON.Decode.string)->Option.map(v => v < beforeKey)->Option.getOr(false)
                )
              | None => allItems
              }
            } else {
              switch after->Option.map(decodeCursor) {
              | Some(afterKey) =>
                allItems->Array.filter(item =>
                  item->JSON.Decode.object->Option.flatMap(d => d->Dict.get(sf))->Option.flatMap(JSON.Decode.string)->Option.map(v => v > afterKey)->Option.getOr(false)
                )
              | None => allItems
              }
            }

            // Apply SortKey_Filter for prefix/from/to/eq
            let filtered = SortKey_Filter.apply(
              ~items=cursorFiltered,
              ~skField=sf,
              ~prefix=?filterPrefix,
              ~from=?filterFrom,
              ~to_=?filterTo,
              ~eq=?filterEq,
              ~reverse=if isBackward { !orderDesc } else { orderDesc },
              ~offset=0,
            ).items

            // For backward pagination flip to logical order after taking
            let (pageItems, hasMore) = switch (isBackward, last, first) {
            | (true, Some(n), _) =>
              let take = n + 1
              let taken = filtered->Array.slice(~start=0, ~end=take)
              let hasMore = taken->Array.length > n
              let result = taken->Array.slice(~start=0, ~end=n)->Array.toReversed
              (result, hasMore)
            | (_, _, Some(n)) =>
              let take = n + 1
              let taken = filtered->Array.slice(~start=0, ~end=take)
              let hasMore = taken->Array.length > n
              (taken->Array.slice(~start=0, ~end=n), hasMore)
            | _ => (filtered, false)
            }

            let getSkValue = item =>
              item->JSON.Decode.object->Option.flatMap(d => d->Dict.get(sf))->Option.flatMap(JSON.Decode.string)->Option.getOr("")

            let edges = pageItems->Array.map(item =>
              Obj.magic({"node": item, "cursor": encodeCursor(getSkValue(item))})
            )
            let startCursor = pageItems->Array.get(0)->Option.map(item => encodeCursor(getSkValue(item)))
            let endCursor   = pageItems->Array.get(pageItems->Array.length - 1)->Option.map(item => encodeCursor(getSkValue(item)))

            Obj.magic({
              "edges": edges,
              "pageInfo": {
                "hasNextPage": !isBackward && hasMore,
                "hasPreviousPage": isBackward && hasMore,
                "startCursor": startCursor->Nullable.fromOption,
                "endCursor": endCursor->Nullable.fromOption,
              },
            })
          }
        }
      }
      [(singleQueryName ++ "Items", resolver)]
    | None => []
    }

    // -- Index queries: {name}By{Index} ---------------------------------------
    let indexSdlFields = indexes->Array.map((ic: Reventless.ReadModel.indexConfig) =>
      `  ${singleQueryName}By${cap(ic.index)}(${ic.index}: String!): [String]`
    )
    let indexResolvers: array<(string, ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn)> = indexes->Array.map(
      (ic: Reventless.ReadModel.indexConfig) => {
        let index = ic.index
        let resolverName = singleQueryName ++ "By" ++ cap(index)
        let filterField = ic.idField->Option.getOr(index)
        let resolver: ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
          switch await runInterceptor(~ctx, ~args) {
          | Deny(_) => []->JSON.Encode.array
          | Allow =>
            let value =
              args->JSON.Decode.object->Option.flatMap(d => d->Dict.get(index))->Option.flatMap(JSON.Decode.string)->Option.getOr("")
            // Applied to whichever arm answers, rather than inside one of them: the
            // push-down and the scan are two ways to reach the same rows, and a
            // narrowing that lives in only one is a hole that appears when a
            // backend gains or loses an index.
            let scoped = rows =>
              rows->Array.filter(item => ownerAllows(~ctx, item) && retiredAllows(~ctx, ~args, item))
            // Prefer the pushed-down equality lookup (SQLite rides the GSI index;
            // in-memory reuses its lazy snapshot). Fall back to scan+filter only
            // if no lookup is registered for this QueryDb.
            switch Bus.getQueryDbIndexLookup(name) {
            | Some(lookup) => lookup(filterField, value)->scoped->JSON.Encode.array
            | None =>
              switch Bus.getQueryDbScan(name) {
              | Some(scanAll) =>
                scanAll()
                ->Array.filter(item =>
                  item
                  ->JSON.Decode.object
                  ->Option.flatMap(d => d->Dict.get(filterField))
                  ->Option.flatMap(JSON.Decode.string)
                  ->Option.map(v => v == value)
                  ->Option.getOr(false)
                )
                ->scoped
                ->JSON.Encode.array
              | None => []->JSON.Encode.array
              }
            }
          }
        }
        (resolverName, resolver)
      },
    )

    // -- Register all fields --------------------------------------------------
    let allSdl =
      [byIdSdl]
      ->Array.concat(byIdsSdl)
      ->Array.concat(listSdl)
      ->Array.concat(itemsSdl)
      ->Array.concat(indexSdlFields)

    let resolvers = Dict.make()
    resolvers->Dict.set(singleQueryName, byIdResolver)
    byIdsResolverEntry->Option.forEach(((k, v)) => resolvers->Dict.set(k, v))
    listResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    itemsResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    indexResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    server.registerQueries(~sdlFields=allSdl, ~resolvers)

    {
      resources: [],
      resourcesMaker: _ => [],
    }
  }

}
