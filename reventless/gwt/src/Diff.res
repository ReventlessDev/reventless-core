// Produces a structural `fieldDiff` for the JSON format (§3.3) and TAP
// emitters. Walks two JSON values and returns a list of differing leaves
// as `{path, expected, actual}` entries. Rendered values use
// `RenderRescript.render` so diff rows read as ReScript, not JSON.

type entry = {
  path: string,
  expected: string,
  actual: string,
}

let joinPath = (prefix, segment) =>
  if prefix == "" {
    segment
  } else {
    prefix ++ "." ++ segment
  }

let rec walk = (~path="", expected: JSON.t, actual: JSON.t, acc: array<entry>) =>
  switch (expected, actual) {
  | (Object(e), Object(a)) =>
    let keys =
      Array.concat(e->Dict.keysToArray, a->Dict.keysToArray)
      ->Array.reduce([], (uniq, k) =>
        if Array.includes(uniq, k) {
          uniq
        } else {
          Array.concat(uniq, [k])
        }
      )
    keys->Array.reduce(acc, (acc, k) => {
      let childExpected =
        e->Dict.get(k)->Option.getOr(JSON.Encode.null)
      let childActual =
        a->Dict.get(k)->Option.getOr(JSON.Encode.null)
      walk(~path=joinPath(path, k), childExpected, childActual, acc)
    })
  | (Array(e), Array(a)) =>
    let lenE = e->Array.length
    let lenA = a->Array.length
    let len = lenE > lenA ? lenE : lenA
    let rec loop = (i, acc) =>
      if i >= len {
        acc
      } else {
        let childExpected =
          e->Array.get(i)->Option.getOr(JSON.Encode.null)
        let childActual =
          a->Array.get(i)->Option.getOr(JSON.Encode.null)
        let acc = walk(
          ~path=joinPath(path, Int.toString(i)),
          childExpected,
          childActual,
          acc,
        )
        loop(i + 1, acc)
      }
    loop(0, acc)
  | _ =>
    if expected == actual {
      acc
    } else {
      Array.concat(
        acc,
        [
          {
            path,
            expected: RenderRescript.render(expected),
            actual: RenderRescript.render(actual),
          },
        ],
      )
    }
  }

let diff = (expected: JSON.t, actual: JSON.t): array<entry> =>
  walk(expected, actual, [])

let diffArrays = (expected: array<JSON.t>, actual: array<JSON.t>): array<entry> =>
  walk(JSON.Encode.array(expected), JSON.Encode.array(actual), [])

let toJson = (e: entry): JSON.t => {
  let obj = Dict.make()
  obj->Dict.set("path", JSON.Encode.string(e.path))
  obj->Dict.set("expected", JSON.Encode.string(e.expected))
  obj->Dict.set("actual", JSON.Encode.string(e.actual))
  JSON.Encode.object(obj)
}

let toJsonArray = (entries: array<entry>): JSON.t =>
  entries->Array.map(toJson)->JSON.Encode.array
