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

// Build the Relay connection object from an already-ordered page. Shared by
// `run` and the SQLite push-down so edges / cursors / pageInfo have one shape.
let buildConnection = (
  ~pageItems: array<JSON.t>,
  ~hasNextPage: bool,
  ~hasPreviousPage: bool,
  ~cursorValueOf: JSON.t => string,
): JSON.t => {
  let edges =
    pageItems->Array.map(item => Obj.magic({"node": item, "cursor": encodeCursor(cursorValueOf(item))}))
  let startCursor = pageItems->Array.get(0)->Option.map(item => encodeCursor(cursorValueOf(item)))
  let endCursor =
    pageItems->Array.get(pageItems->Array.length - 1)->Option.map(item => encodeCursor(cursorValueOf(item)))
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
  ~retiredScope: option<string>=?,
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
  let perFieldChecks: array<JSON.t => bool> = capability.filterFields->Array.flatMap(f => {
    let checks: array<JSON.t => bool> = []
    switch filterDict->Dict.get(f.name ++ "Eq") {
    | Some(v) when v != JSON.Encode.null =>
      let expected = switch v->JSON.Decode.string {
      | Some(s) => s
      | None => v->JSON.Decode.float->Option.map(f => Float.toString(f))->Option.getOr("")
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
          ->Option.getOr(v->JSON.Decode.float->Option.map(f => Float.toString(f))->Option.getOr(""))
        checks->Array.push(item => getFieldString(item, f.name)->Option.mapOr(false, v => v >= from))
      | _ => ()
      }
      switch filterDict->Dict.get(f.name ++ "To") {
      | Some(v) when v != JSON.Encode.null =>
        let to_ =
          v
          ->JSON.Decode.string
          ->Option.getOr(v->JSON.Decode.float->Option.map(f => Float.toString(f))->Option.getOr(""))
        checks->Array.push(item => getFieldString(item, f.name)->Option.mapOr(false, v => v <= to_))
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
    | Some((field, required)) =>
      getFieldString(item, field)->Option.mapOr(false, v => v == required)
    | None => true
    }
    // The mirror image of `passOwner`'s missing-field rule, and it lands the
    // opposite way for the same reason. An owner-scoped read excludes a row that
    // states no owner, because such a row belongs to nobody in particular. A
    // retirement read KEEPS a row that states no flag: absent means not retired,
    // which is what a row written before the annotation existed is. Excluding
    // those would empty the view the day the annotation lands.
    let passRetired = switch retiredScope {
    | Some(field) => getFieldBool(item, field)->Option.getOr(false) == false
    | None => true
    }
    passSearch && passPrefix && passIds && passPerField && passOwner && passRetired
  })

  let orderByDict = argsDict->Dict.get("orderBy")->Option.flatMap(JSON.Decode.object)
  let orderByField =
    orderByDict->Option.flatMap(ob => ob->Dict.get("field"))->Option.flatMap(JSON.Decode.string)
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

  let first =
    argsDict->Dict.get("first")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
  let after = argsDict->Dict.get("after")->Option.flatMap(JSON.Decode.string)
  let last = argsDict->Dict.get("last")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
  let before = argsDict->Dict.get("before")->Option.flatMap(JSON.Decode.string)
  let isBackward = last->Option.isSome
  let cursorField = orderByField->Option.getOr("id")
  let getCursorValue = item => getFieldString(item, cursorField)->Option.getOr(getId(item))

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

  buildConnection(
    ~pageItems,
    ~hasNextPage=!isBackward && hasMore,
    ~hasPreviousPage=isBackward && hasMore,
    ~cursorValueOf=getCursorValue,
  )
}
