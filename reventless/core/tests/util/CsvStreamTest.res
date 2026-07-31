// CsvStreamTest.res
// Tests for CsvStream.parseRows — Effect Stream bridge for FastCSV.
// See docs/plans/effect-stream-integration.md Phase E.

open JestGlobals

// Counter for unique temp file names — avoids cross-test collisions.
let fileCounter = ref(0)

let writeTempCsv = (content: string): string => {
  fileCounter := fileCounter.contents + 1
  let path = `/tmp/reventless-csvstream-test-${Int.toString(fileCounter.contents)}.csv`
  NodeFs.writeFileSync(path, content)
  path
}

describe("CsvStream.parseRows", () => {
  testPromise("parses all rows from a small CSV file", async () => {
    let path = writeTempCsv("name,age\nAlice,30\nBob,25")
    let rows = await CsvStream.parseRows(~path)->Stream.runCollect->Effect.runPromise
    expect(rows->Array.length)->toBe(2)
  })

  testPromise("emits rows in file order", async () => {
    let path = writeTempCsv("name\nfirst\nsecond\nthird")
    let first = await CsvStream.parseRows(~path)->Stream.runHead->Effect.runPromise
    // first: option<CSV.row> — unwrap and check the "name" field
    let name = first->Option.flatMap(row => row->Dict.get("name"))
    expect(name)->toEqual(Some("first"))
  })

  testPromise("take(2) returns only 2 rows", async () => {
    // Build a CSV with 10 data rows; take(2) must return exactly 2
    let dataRows =
      Array.make(~length=10, 0)
      ->Array.mapWithIndex((i, _) => `row-${Int.toString(i)}`)
      ->Array.join("\n")
    let path = writeTempCsv("name\n" ++ dataRows)
    let result = await CsvStream.parseRows(~path)
      ->Stream.take(2)
      ->Stream.runCollect
      ->Effect.runPromise
    expect(result->Array.length)->toBe(2)
  })

  testPromise("empty CSV file (header only) returns empty stream", async () => {
    let path = writeTempCsv("name")
    let rows = await CsvStream.parseRows(~path)->Stream.runCollect->Effect.runPromise
    expect(rows->Array.length)->toBe(0)
  })
})
