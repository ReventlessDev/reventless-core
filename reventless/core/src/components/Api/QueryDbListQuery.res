// The connection-list filter / sort / keyset-paginate logic, extracted verbatim
// from QueryDbResolvers_GraphQL so there is ONE source of truth for the
// semantics. The in-memory / GraphQL resolver calls `run` over the materialised
// items; the SQLite backend's list push-down (reventless-local) and the Postgres
// resolver Lambda (reventless-aws) must reproduce these exact semantics, and the
// parity harness asserts they do. Kept pure (no server / storage dependencies —
// the one server helper it needs, global-id decoding for the `ids` filter, is
// passed in) so it can be the shared spec every backend is tested against.
//
// Lives in reventless-core (not reventless-local) so both the local SQLite path
// and the AWS Postgres resolver path can share it without a layering violation —
// `GraphQL_FragmentGenerator.serverCapability`, its only dependency, is a sibling
// here.

// base64 cursor of the active sort field's value. Shared with the resolver's
// items (sub-id) connection so cursor encoding stays in lockstep.
@val external btoa: string => string = "btoa"
@val external atob: string => string = "atob"
let encodeCursor = (value: string): string => btoa(value)
let decodeCursor = (cursor: string): string => atob(cursor)

// Default page size when neither `first` nor `last` is supplied — a bound is
// required for keyset `pageInfo` to be reported correctly.
let defaultListPageSize = 50

// The effective id of an item (its "id" field). Shared with the SQLite
// push-down so both compute the tiebreak / default-cursor value identically.
let getId = (item: JSON.t): string =>
  item
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("id"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("")

// String form of a field for comparison / cursor purposes: the string itself,
// or a number rendered via Float.toString, else None. The push-down must render
// the same string in SQL (CAST … AS TEXT) for cursor/order parity.
// A boolean field's value, or None when the row does not carry one. Separate
// from `getFieldString` rather than reusing it: JSON `true` stringifies to
// nothing useful, and a retirement predicate read off a coerced string would
// treat `"false"` — a legitimate value for a field someone stored as text — as
// truthy and hide the row.
let getFieldBool = (item: JSON.t, field: string): option<bool> =>
  item
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get(field))
  ->Option.flatMap(JSON.Decode.bool)

let getFieldString = (item: JSON.t, field: string): option<string> =>
  item
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get(field))
  ->Option.flatMap(v =>
    switch v->JSON.Decode.string {
    | Some(s) => Some(s)
    | None => v->JSON.Decode.float->Option.map(f => Float.toString(f))
    }
  )

// Order two rendered values: as numbers when the field is numeric and both
// parse, else as text. An absent value renders as "" and so keeps its text place.
let compareValues = (~numeric: bool, a: string, b: string): int =>
  switch numeric ? (Float.fromString(a), Float.fromString(b)) : (None, None) {
  | (Some(x), Some(y)) => x < y ? -1 : x > y ? 1 : 0
  | _ => a < b ? -1 : a > b ? 1 : 0
  }

/** A field's value as a list orders by it: `getFieldString`, with a boolean as `"0"` or `"1"`
    (the capability marks a sorted boolean numeric). */
let getSortString = (item: JSON.t, field: string): option<string> =>
  switch getFieldBool(item, field) {
  | Some(b) => Some(b ? "1" : "0")
  | None => getFieldString(item, field)
  }

/** Where a row sits in a list ordered by a field: its value (`None` when it has none) and its id. */
type position = {value: option<string>, id: string}

let positionOf = (item: JSON.t, ~field: string): position => {
  value: getSortString(item, field),
  id: getId(item),
}

@val external encodeURIComponent: string => string = "encodeURIComponent"
@val external decodeURIComponent: string => string = "decodeURIComponent"
@val external escape: string => string = "escape"
@val external unescape: string => string = "unescape"

/** An ordered list's cursor: the value and the id, as UTF-8 JSON in base64. */
let encodePosition = (p: position): string =>
  btoa(
    unescape(
      encodeURIComponent(
        JSON.stringify(
          JSON.Encode.array([
            p.value->Option.mapOr(JSON.Encode.null, JSON.Encode.string),
            JSON.Encode.string(p.id),
          ]),
        ),
      ),
    ),
  )

/** The position a cursor names. A cursor that holds a value alone, as one minted before cursors
    carried the id, is read as that value with no id. */
let decodePosition = (cursor: string): position => {
  let raw = atob(cursor)
  let pair = try {
    switch JSON.parseOrThrow(decodeURIComponent(escape(raw)))->JSON.Decode.array {
    | Some([value, id]) =>
      id->JSON.Decode.string->Option.map(id => {value: value->JSON.Decode.string, id})
    | _ => None
    }
  } catch {
  | _ => None
  }
  pair->Option.getOr({value: Some(raw), id: ""})
}

/** The order of two positions: by value in the direction asked, rows without one last either
    way, then by id. */
let comparePositions = (~numeric: bool, ~isDesc: bool, a: position, b: position): int => {
  let byId = a.id < b.id ? -1 : a.id > b.id ? 1 : 0
  switch (a.value, b.value) {
  | (Some(av), Some(bv)) =>
    let primary = compareValues(~numeric, av, bv)
    switch isDesc ? -primary : primary {
    | 0 => byId
    | p => p
    }
  | (Some(_), None) => -1
  | (None, Some(_)) => 1
  | (None, None) => byId
  }
}

/** The cursor of a row: its position in a list ordered by `orderByField`, else its id. */
let cursorOf = (~orderByField: option<string>, item: JSON.t): string =>
  switch orderByField {
  | Some(field) => encodePosition(positionOf(item, ~field))
  | None => encodeCursor(getId(item))
  }

// Build the Relay connection object from an already-ordered page. Shared by
// `run` and the SQLite push-down so edges / cursors / pageInfo have one shape.
let buildConnection = (
  ~pageItems: array<JSON.t>,
  ~hasNextPage: bool,
  ~hasPreviousPage: bool,
  ~cursorOf: JSON.t => string,
): JSON.t => {
  let edges = pageItems->Array.map(item => Obj.magic({"node": item, "cursor": cursorOf(item)}))
  let startCursor = pageItems->Array.get(0)->Option.map(cursorOf)
  let endCursor = pageItems->Array.get(pageItems->Array.length - 1)->Option.map(cursorOf)
  Obj.magic({
    "edges": edges,
    "pageInfo": {
      "hasNextPage": hasNextPage,
      "hasPreviousPage": hasPreviousPage,
      "startCursor": startCursor->Nullable.fromOption,
      "endCursor": endCursor->Nullable.fromOption,
    },
  })
}

// Compute the Relay connection response (edges + pageInfo) for `items` under the
// GraphQL args. `decodeLocalId` maps a possibly-Relay-encoded id to its local id;
// it defaults to the shared rule so every caller applies the same one — the AWS
// Lambda used to pass a no-op here, which silently made `filter.ids` reject a
// global id on that provider only. Everything else is pure over the item array.
// `ownerScope` is `(fieldName, requiredValue)`, and it is deliberately NOT read
// out of `argsDict`. Two reasons, both fatal to the obvious alternative of
// injecting `filter.<owner>Eq`:
//
//   - the owner field usually is not in `capability.filterFields` at all (it is
//     admitted only by `@id` / `@index` / `@scan` and friends), so there is no
//     filter input to inject into; and
//   - `filter` is the caller's own argument. A predicate that decides what the
//     caller may see must arrive on a channel the caller cannot name or
//     overwrite.
//
// It joins the same `filtered` pass as everything else, which puts it BEFORE
// ordering and pagination. Narrowing a materialised page afterwards would return
// short pages with valid-looking cursors — a bug that reads as "the list
// sometimes ends early" rather than as an access-control fault.
let run = (
  ~items: array<JSON.t>,
  ~argsDict: Dict.t<JSON.t>,
  ~capability: GraphQL_FragmentGenerator.serverCapability,
  ~labelField: string,
  ~decodeLocalId: string => option<string>=Api_Ids.toLocalId,
  ~ownerScope: option<(string, string)>=?,
  ~retiredScope: option<Reventless.OwnerScope.retiredScope>=?,
): JSON.t => {
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
  // Per-field eq / from / to filters derived from capability — applied alongside
  // the legacy search/searchPrefix/ids block.
  let stored = name => GraphQL_FragmentGenerator.storedName(capability, name)
  let perFieldChecks: array<JSON.t => bool> = capability.filterFields->Array.flatMap(f => {
    let attr = stored(f.name)
    let cmp = compareValues(~numeric=GraphQL_FragmentGenerator.isNumeric(capability, f.name), ...)
    let checks: array<JSON.t => bool> = []
    switch filterDict->Dict.get(f.name ++ "Eq") {
    | Some(v) if v != JSON.Encode.null =>
      let expected = switch v->JSON.Decode.string {
      | Some(s) => s
      | None => v->JSON.Decode.float->Option.map(f => Float.toString(f))->Option.getOr("")
      }
      checks->Array.push(item =>
        getFieldString(item, attr)->Option.mapOr(false, v => v == expected)
      )
    | _ => ()
    }
    if f.range {
      switch filterDict->Dict.get(f.name ++ "From") {
      | Some(v) if v != JSON.Encode.null =>
        let from =
          v
          ->JSON.Decode.string
          ->Option.getOr(v->JSON.Decode.float->Option.map(f => Float.toString(f))->Option.getOr(""))
        checks->Array.push(item =>
          getFieldString(item, attr)->Option.mapOr(false, v => cmp(v, from) >= 0)
        )
      | _ => ()
      }
      switch filterDict->Dict.get(f.name ++ "To") {
      | Some(v) if v != JSON.Encode.null =>
        let to_ =
          v
          ->JSON.Decode.string
          ->Option.getOr(v->JSON.Decode.float->Option.map(f => Float.toString(f))->Option.getOr(""))
        checks->Array.push(item =>
          getFieldString(item, attr)->Option.mapOr(false, v => cmp(v, to_) <= 0)
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
    // Either id form matches, in both directions: the argument may be a Relay
    // global id while the row carries its storage key (the normal case — every
    // door but `node` reports the storage key), and the row may carry a global id
    // where some caller stamped one. Decoding only the row's id, as this did,
    // covered just the second.
    let passIds = switch ids {
    | Some(idList) if idList->Array.length > 0 =>
      let itemId = getId(item)
      let itemLocalId = decodeLocalId(itemId)
      idList->Array.some(i =>
        i == itemId || itemLocalId == Some(i) || decodeLocalId(i) == Some(itemId)
      )
    | _ => true
    }
    let passPerField = perFieldChecks->Array.every(check => check(item))
    // A row that does not state an owner never matches a scoped read. Treating a
    // missing field as "belongs to everyone" would expose exactly the rows that
    // predate the annotation, which are the ones nobody remembers to check.
    let passOwner = switch ownerScope {
    | Some((field, required)) => item->Reventless.OwnerScope.ownsRow(~field, ~required)
    | None => true
    }
    // The missing-field rule lives in `OwnerScope.isRetiredValue`, beside the two
    // forms it has to answer for; the note on why it lands the opposite way from
    // `passOwner` is there.
    let passRetired = switch retiredScope {
    | Some(scope) => scope->Reventless.OwnerScope.keepsRow(item)
    | None => true
    }
    passSearch && passPrefix && passIds && passPerField && passOwner && passRetired
  })

  let orderByDict = argsDict->Dict.get("orderBy")->Option.flatMap(JSON.Decode.object)
  let orderByName =
    orderByDict
    ->Option.flatMap(ob => ob->Dict.get("field"))
    ->Option.flatMap(JSON.Decode.string)
  let orderByField = orderByName->Option.map(stored)
  let orderNumeric =
    orderByName->Option.mapOr(false, GraphQL_FragmentGenerator.isNumeric(capability, ...))
  // Ordering by a state's date lists the rows that entered the state.
  let filtered = switch (orderByName, orderByField) {
  | (Some(name), Some(attr)) if GraphQL_FragmentGenerator.onlyReached(capability, name) =>
    filtered->Array.filter(item => getFieldString(item, attr)->Option.isSome)
  | _ => filtered
  }
  let direction =
    orderByDict
    ->Option.flatMap(ob => ob->Dict.get("direction"))
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOr("ASC")
  let isDesc = direction == "DESC"
  // Without an order, by id: a position with no value compares by id alone.
  let positionIn = item =>
    switch orderByField {
    | Some(field) => positionOf(item, ~field)
    | None => {value: None, id: getId(item)}
    }
  let compare = comparePositions(~numeric=orderNumeric, ~isDesc, ...)
  let sorted =
    filtered->Array.toSorted((a, b) => compare(positionIn(a), positionIn(b))->Int.toFloat)

  let first =
    argsDict->Dict.get("first")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
  // An empty cursor is no cursor. The host shell clears the opposite argument by
  // setting it to "" rather than dropping it, and `Some("")` read as a cursor
  // bounds nothing while still selecting the branch that expects one.
  let cursorArg = key =>
    argsDict
    ->Dict.get(key)
    ->Option.flatMap(JSON.Decode.string)
    ->Option.flatMap(s => s == "" ? None : Some(s))
  let after = cursorArg("after")
  let last = argsDict->Dict.get("last")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
  let before = cursorArg("before")
  // `before` decides the direction, not `last`. Relay pairs `last` with `before`,
  // but a client that keeps its page size in `first` and only moves the cursor
  // sends `before` alone — and keying on `last` made that a FORWARD read bounded
  // by nothing, which answers page one and calls it the previous page.
  let isBackward = last->Option.isSome || before->Option.isSome
  let cursorPosition = c =>
    switch orderByField {
    | Some(_) => decodePosition(c)
    | None => {value: None, id: decodeCursor(c)}
    }
  let cursorBounded = switch (isBackward, after, before) {
  | (false, Some(c), _) =>
    let at = cursorPosition(c)
    sorted->Array.filter(item => compare(positionIn(item), at) > 0)
  | (true, _, Some(c)) =>
    let at = cursorPosition(c)
    sorted->Array.filter(item => compare(positionIn(item), at) < 0)
  | _ => sorted
  }

  // `last` when given, else the page size the caller has been paging with.
  let pageSize = if isBackward {
    switch last {
    | Some(n) => n
    | None => first->Option.getOr(defaultListPageSize)
    }
  } else {
    first->Option.getOr(defaultListPageSize)
  }
  let take = pageSize + 1
  let (pageItems, hasMore) = if isBackward {
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

  // Both directions report both flags. A backward page was cut from ahead, so a
  // next page provably exists — the one the caller came from — and a forward page
  // reached by a cursor has one behind it. Reporting only the flag that matches
  // the direction made Prev vanish the moment it was used.
  buildConnection(
    ~pageItems,
    ~hasNextPage=isBackward ? true : hasMore,
    ~hasPreviousPage=isBackward ? hasMore : after->Option.isSome,
    ~cursorOf=cursorOf(~orderByField, ...),
  )
}
