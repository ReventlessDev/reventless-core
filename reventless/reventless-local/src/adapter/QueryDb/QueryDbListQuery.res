// The connection-list filter / sort / keyset-paginate logic, extracted verbatim
// from QueryDbResolvers_GraphQL so there is ONE source of truth for the
// semantics. The resolver calls `run` over the materialised items (in-memory
// path); the SQLite backend's list push-down must reproduce these exact
// semantics, and the parity harness asserts it does. Keeping this pure (no
// server / storage dependencies — the one server helper it needs, global-id
// decoding for the `ids` filter, is passed in) is what lets it be the shared
// spec both paths are tested against.

open ReventlessCore

// base64 cursor of the active sort field's value. Shared with the resolver's
// items (sub-id) connection so cursor encoding stays in lockstep.
@val external btoa: string => string = "btoa"
@val external atob: string => string = "atob"
let encodeCursor = (value: string): string => btoa(value)
let decodeCursor = (cursor: string): string => atob(cursor)

// Default page size when neither `first` nor `last` is supplied — a bound is
// required for keyset `pageInfo` to be reported correctly.
let defaultListPageSize = 50

// Compute the Relay connection response (edges + pageInfo) for `items` under the
// GraphQL args. `decodeLocalId` maps a possibly-Relay-encoded id to its local id
// (the resolver passes DomainGraphQL_Server.decodeGlobalId); everything else is
// pure over the item array.
let run = (
  ~items: array<JSON.t>,
  ~argsDict: Dict.t<JSON.t>,
  ~capability: GraphQL_FragmentGenerator.serverCapability,
  ~labelField: string,
  ~decodeLocalId: string => option<string>,
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
  let getId = item =>
    item
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("id"))
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOr("")
  // Per-field eq / from / to filters derived from capability — applied alongside
  // the legacy search/searchPrefix/ids block.
  let getFieldString = (item, field) =>
    item
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get(field))
    ->Option.flatMap(v =>
      switch v->JSON.Decode.string {
      | Some(s) => Some(s)
      | None => v->JSON.Decode.float->Option.map(f => Float.toString(f))
      }
    )
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
    let passIds = switch ids {
    | Some(idList) if idList->Array.length > 0 =>
      let itemId = getId(item)
      let itemLocalId = decodeLocalId(itemId)
      idList->Array.some(i => i == itemId || itemLocalId == Some(i))
    | _ => true
    }
    let passPerField = perFieldChecks->Array.every(check => check(item))
    passSearch && passPrefix && passIds && passPerField
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

  let edges =
    pageItems->Array.map(item => Obj.magic({"node": item, "cursor": encodeCursor(getCursorValue(item))}))
  let startCursor = pageItems->Array.get(0)->Option.map(item => encodeCursor(getCursorValue(item)))
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
