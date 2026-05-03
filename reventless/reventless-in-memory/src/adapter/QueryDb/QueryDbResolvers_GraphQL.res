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

// Shared keyset-cursor helpers. The cursor is base64 of the row's value for the
// active sort field (orderBy.field, or "id" when no orderBy is supplied). Used
// by both the connection list resolver and the items resolver so cursor encoding
// stays in lockstep.
let encodeCursor = (value: string): string => btoa(value)
let decodeCursor = (cursor: string): string => atob(cursor)

// Default page size for the connection list resolver when neither `first` nor
// `last` is supplied. Matches the UI's `defaultPageSize` constant; a bound is
// necessary for the keyset model to report `pageInfo` correctly.
let defaultListPageSize = 50

module Make = (Bus: InMemory_Bus.T) => {
  open ReventlessCore

  type api = unit
  type role = unit

  // -- Identity extraction from GraphQL context ---------------------------------
  // graphql-yoga provides { request: Request, ... } as the resolver context.
  // We read the X-Identity header (JSON-encoded Identity.t) and fall back to anonymous.

  @send external getHeader: ('headers, string) => Nullable.t<string> = "get"

  let extractIdentity = (ctx: JSON.t): Reventless.Identity.t => {
    try {
      let request = (ctx->Obj.magic)["request"]
      let headers = request["headers"]
      switch headers->getHeader("x-identity")->Nullable.toOption {
      | Some(json) => json->JSON.parseOrThrow->S.parseOrThrow(Reventless.Identity.schema)
      | None => Reventless.Identity.anonymous
      }
    } catch {
    | _ => Reventless.Identity.anonymous
    }
  }

  // -- Module-level server and relay refs ------------------------------------
  // Set by Platform.res before component construction runs so the make function
  // can pick up the correct target server and relay support (mirrors AWS ~api pattern).
  let serverRef: ref<GraphQL_ServerInstance.t> = ref(DomainGraphQL_Server.asInterface)
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
    ~opts as _,
  ) => {
    // Read the active server and relay support from module-level refs set by Platform.res.
    // This mirrors how AWS adapters receive ~api from the hook; here the hook sets the refs
    // before calling make() so the values are available at registration time.
    let server = serverRef.contents
    let relay = relayRef.contents

    // Register the Relay node resolver callback once per QueryDb (domain only).
    // Scans all QueryDb instances to resolve node(id: ID!) queries.
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
            let obj = item->JSON.Decode.object->Option.getOr(Dict.make())
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
      switch QueryDb_Callback.queryInterceptorHook.contents {
      | None => Allow
      | Some(interceptor) =>
        await interceptor(
          ~identity=extractIdentity(ctx),
          ~readModelName=name,
          ~args,
        )
      }
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

    let encodeId = switch relay {
    | Some(r) => (~typeName, ~localId) => r.encodeGlobalId(~typeName, ~localId)
    | None => (~typeName as _, ~localId) => localId
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
    let byIdResolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
      switch await runInterceptor(~ctx, ~args) {
      | Deny(_) => JSON.Encode.null
      | Allow =>
        let id =
          args->JSON.Decode.object->Option.flatMap(d => d->Dict.get("id"))->Option.flatMap(JSON.Decode.string)->Option.getOr("")
        switch Bus.getQueryDb(name) {
        | Some(ops) =>
          let items =
            await ops.loadStream(id)
            ->Stream.runCollect
            ->Effect.catchAll(_ => Effect.succeed([]))
            ->Effect.runPromise
          switch items->Array.get(0) {
          | Some(item) =>
            if includeIdParam {
              let obj = item->JSON.Decode.object->Option.getOr(Dict.make())
              obj->Dict.set("id", encodeId(~typeName=returnTypeName, ~localId=id)->JSON.Encode.string)
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
    | Some(s) => GraphQL_FragmentGenerator.deriveServerCapability(s)
    | None => GraphQL_FragmentGenerator.emptyCapability
    }
    let (listSdl, listResolver): (array<string>, GraphQL_ServerInstance.resolverFn) = if connectionSpec {
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
      let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
        switch await runInterceptor(~ctx, ~args) {
        | Deny(_) =>
          Obj.magic({
            "edges": [],
            "pageInfo": {
              "hasNextPage": false,
              "hasPreviousPage": false,
              "startCursor": Nullable.null,
              "endCursor": Nullable.null,
            },
          })
        | Allow =>
          let items = switch Bus.getQueryDbStream(name) {
          | Some(makeStream) =>
            await makeStream()->Stream.runCollect->Effect.runPromise
          | None =>
            switch Bus.getQueryDbScan(name) {
            | Some(scanAll) => scanAll()
            | None => []
            }
          }
          // Apply filter (search, searchPrefix, ids) before any pagination.
          let argsDict = args->JSON.Decode.object->Option.getOr(Dict.make())
          let filterDict =
            argsDict->Dict.get("filter")->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
          let search = filterDict->Dict.get("search")->Option.flatMap(JSON.Decode.string)
          let searchPrefix = filterDict->Dict.get("searchPrefix")->Option.flatMap(JSON.Decode.string)
          let ids =
            filterDict
            ->Dict.get("ids")
            ->Option.flatMap(JSON.Decode.array)
            ->Option.map(arr => arr->Array.filterMap(JSON.Decode.string))
          let getLabel = item =>
            item
            ->JSON.Decode.object
            ->Option.flatMap(d => d->Dict.get(labelField))
            ->Option.flatMap(JSON.Decode.string)
            ->Option.getOr("")
          let getId = item =>
            item
            ->JSON.Decode.object
            ->Option.flatMap(d => d->Dict.get("id"))
            ->Option.flatMap(JSON.Decode.string)
            ->Option.getOr("")
          // Per-field eq / from / to filters derived from capability — applied
          // alongside the legacy search/searchPrefix/ids block.
          let getFieldString = (item, field) =>
            item
            ->JSON.Decode.object
            ->Option.flatMap(d => d->Dict.get(field))
            ->Option.flatMap(v =>
              switch v->JSON.Decode.string {
              | Some(s) => Some(s)
              | None =>
                v
                ->JSON.Decode.float
                ->Option.map(f => Float.toString(f))
              }
            )
          let perFieldChecks: array<JSON.t => bool> = capability.filterFields->Array.flatMap(f => {
            let checks: array<JSON.t => bool> = []
            switch filterDict->Dict.get(f.name ++ "Eq") {
            | Some(v) when v != JSON.Encode.null =>
              let expected = switch v->JSON.Decode.string {
              | Some(s) => s
              | None =>
                v->JSON.Decode.float->Option.map(f => Float.toString(f))->Option.getOr("")
              }
              checks->Array.push(item =>
                getFieldString(item, f.name)->Option.mapOr(false, v => v == expected)
              )
            | _ => ()
            }
            if f.range {
              switch filterDict->Dict.get(f.name ++ "From") {
              | Some(v) when v != JSON.Encode.null =>
                let from =
                  v
                  ->JSON.Decode.string
                  ->Option.getOr(
                    v->JSON.Decode.float->Option.map(f => Float.toString(f))->Option.getOr(""),
                  )
                checks->Array.push(item =>
                  getFieldString(item, f.name)->Option.mapOr(false, v => v >= from)
                )
              | _ => ()
              }
              switch filterDict->Dict.get(f.name ++ "To") {
              | Some(v) when v != JSON.Encode.null =>
                let to_ =
                  v
                  ->JSON.Decode.string
                  ->Option.getOr(
                    v->JSON.Decode.float->Option.map(f => Float.toString(f))->Option.getOr(""),
                  )
                checks->Array.push(item =>
                  getFieldString(item, f.name)->Option.mapOr(false, v => v <= to_)
                )
              | _ => ()
              }
            }
            checks
          })

          let filtered = items->Array.filter(item => {
            let passSearch = switch search {
            | Some(s) if s->String.length > 0 =>
              getLabel(item)->String.toLowerCase->String.includes(s->String.toLowerCase)
            | _ => true
            }
            let passPrefix = switch searchPrefix {
            | Some(p) if p->String.length > 0 =>
              getLabel(item)->String.toLowerCase->String.startsWith(p->String.toLowerCase)
            | _ => true
            }
            // Filter `ids` accepts either the Relay-encoded global ID (the
            // form returned by node.id) or the entity's raw local ID — so
            // callers that hold a foreign-key value like `customerId =
            // "cust-1"` can hydrate labels without first encoding to
            // `Ordering_Customer:cust-1` base64.
            let passIds = switch ids {
            | Some(idList) if idList->Array.length > 0 =>
              let itemId = getId(item)
              let itemLocalId =
                DomainGraphQL_Server.decodeGlobalId(itemId)->Option.map(((_, lid)) => lid)
              idList->Array.some(i => i == itemId || itemLocalId == Some(i))
            | _ => true
            }
            let passPerField = perFieldChecks->Array.every(check => check(item))
            passSearch && passPrefix && passIds && passPerField
          })

          // Apply orderBy when provided. Sorts on the requested field; ties
          // broken by id so keyset-style cursors stay stable across requests
          // that share a sort field. When orderBy is omitted, items are sorted
          // by id ascending so the natural order is deterministic and pagination
          // cursors remain stable.
          let orderByDict =
            argsDict
            ->Dict.get("orderBy")
            ->Option.flatMap(JSON.Decode.object)
          let orderByField =
            orderByDict
            ->Option.flatMap(ob => ob->Dict.get("field"))
            ->Option.flatMap(JSON.Decode.string)
          let direction =
            orderByDict
            ->Option.flatMap(ob => ob->Dict.get("direction"))
            ->Option.flatMap(JSON.Decode.string)
            ->Option.getOr("ASC")
          let isDesc = direction == "DESC"
          let sorted = switch orderByField {
          | Some(f) =>
            let cmp = (a, b) => {
              let av = getFieldString(a, f)->Option.getOr("")
              let bv = getFieldString(b, f)->Option.getOr("")
              let primary = if av < bv {
                -1
              } else if av > bv {
                1
              } else {
                0
              }
              let primary = isDesc ? -primary : primary
              if primary != 0 {
                primary
              } else {
                let aid = getId(a)
                let bid = getId(b)
                if aid < bid {
                  -1
                } else if aid > bid {
                  1
                } else {
                  0
                }
              }
            }
            filtered->Array.toSorted((a, b) => cmp(a, b)->Int.toFloat)
          | None =>
            // Default to id-ascending so cursor pagination has a stable order.
            filtered->Array.toSorted((a, b) => {
              let aid = getId(a)
              let bid = getId(b)
              if aid < bid {
                -1.
              } else if aid > bid {
                1.
              } else {
                0.
              }
            })
          }

          // Keyset pagination. Cursor encodes the row's value for the active
          // sort field — orderBy.field when supplied, "id" otherwise. Boundary
          // is applied as a value comparison against the sorted array; in DESC
          // sort the comparison flips. Note: when the cursor field has duplicate
          // values, the boundary excludes all rows with the cursor's value, not
          // just the row at the cursor position. Acceptable for in-memory dev;
          // in practice common sort fields (id, createdAt) are unique.
          let first =
            argsDict->Dict.get("first")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
          let after = argsDict->Dict.get("after")->Option.flatMap(JSON.Decode.string)
          let last =
            argsDict->Dict.get("last")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
          let before = argsDict->Dict.get("before")->Option.flatMap(JSON.Decode.string)
          let isBackward = last->Option.isSome
          let cursorField = orderByField->Option.getOr("id")
          let getCursorValue = item =>
            getFieldString(item, cursorField)->Option.getOr(getId(item))

          let cursorBounded = switch (isBackward, after, before) {
          | (false, Some(c), _) =>
            let cv = decodeCursor(c)
            sorted->Array.filter(item => {
              let v = getCursorValue(item)
              isDesc ? v < cv : v > cv
            })
          | (true, _, Some(c)) =>
            let cv = decodeCursor(c)
            sorted->Array.filter(item => {
              let v = getCursorValue(item)
              isDesc ? v > cv : v < cv
            })
          | _ => sorted
          }

          let pageSize = if isBackward {
            last->Option.getOr(defaultListPageSize)
          } else {
            first->Option.getOr(defaultListPageSize)
          }
          let take = pageSize + 1
          let (pageItems, hasMore) = if isBackward {
            // Take the last `take` items from the cursor-bounded slice. If we
            // grabbed an extra, drop the leading entry (the boundary marker).
            let len = cursorBounded->Array.length
            let startIdx = len > take ? len - take : 0
            let arr = cursorBounded->Array.slice(~start=startIdx, ~end=len)
            let hasMore = arr->Array.length > pageSize
            let result = if hasMore {
              arr->Array.slice(~start=1, ~end=arr->Array.length)
            } else {
              arr
            }
            (result, hasMore)
          } else {
            let arr = cursorBounded->Array.slice(~start=0, ~end=take)
            let hasMore = arr->Array.length > pageSize
            (arr->Array.slice(~start=0, ~end=pageSize), hasMore)
          }

          let edges = pageItems->Array.map(item =>
            Obj.magic({"node": item, "cursor": encodeCursor(getCursorValue(item))})
          )
          let startCursor =
            pageItems->Array.get(0)->Option.map(item => encodeCursor(getCursorValue(item)))
          let endCursor =
            pageItems
            ->Array.get(pageItems->Array.length - 1)
            ->Option.map(item => encodeCursor(getCursorValue(item)))
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
      (sdl, resolver)
    } else {
      // Legacy AppSync-style format
      let sdl = [`  ${listQueryName}(nextToken: String, limit: Int): ${pluralTypeName}!`]
      let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
        switch await runInterceptor(~ctx, ~args) {
        | Deny(_) => Obj.magic({"nextToken": Nullable.null, "scannedCount": 0, "items": []})
        | Allow =>
          let items = switch Bus.getQueryDbStream(name) {
          | Some(makeStream) =>
            await makeStream()->Stream.runCollect->Effect.runPromise
          | None =>
            switch Bus.getQueryDbScan(name) {
            | Some(scanAll) => scanAll()
            | None => []
            }
          }
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
    let itemsResolvers: array<(string, GraphQL_ServerInstance.resolverFn)> = switch subIdField {
    | Some(sf) =>
      let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
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
            let allItems =
              await ops.loadStream(id)
              ->Stream.runCollect
              ->Effect.catchAll(_ => Effect.succeed([]))
              ->Effect.runPromise

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
    let indexResolvers: array<(string, GraphQL_ServerInstance.resolverFn)> = indexes->Array.map(
      (ic: Reventless.ReadModel.indexConfig) => {
        let index = ic.index
        let resolverName = singleQueryName ++ "By" ++ cap(index)
        let filterField = ic.idField->Option.getOr(index)
        let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
          switch await runInterceptor(~ctx, ~args) {
          | Deny(_) => []->JSON.Encode.array
          | Allow =>
            let value =
              args->JSON.Decode.object->Option.flatMap(d => d->Dict.get(index))->Option.flatMap(JSON.Decode.string)->Option.getOr("")
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
              ->JSON.Encode.array
            | None => []->JSON.Encode.array
            }
          }
        }
        (resolverName, resolver)
      },
    )

    // -- Register all fields --------------------------------------------------
    let allSdl =
      [byIdSdl]->Array.concat(listSdl)->Array.concat(itemsSdl)->Array.concat(indexSdlFields)

    let resolvers = Dict.make()
    resolvers->Dict.set(singleQueryName, byIdResolver)
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
