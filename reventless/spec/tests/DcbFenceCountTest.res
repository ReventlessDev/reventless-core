// A reader of a cross-partition index proves it read every event its fence
// counted, and a fence not yet counted proves nothing.

open JestGlobals

let student: Reventless.DcbTag.tag = {key: "studentId", value: "S1"}
let course: Reventless.DcbTag.tag = {key: "courseId", value: "C1"}

let query: Reventless.DcbTag.query = [
  {tags: [course], eventTypes: ["StudentSubscribed"]},
  {tags: [student], eventTypes: ["StudentSubscribed", "StudentLeft"]},
]

let clauses = Reventless.DcbFenceCount.clauses(query, ~crossPartitionTagKeys=["studentId"])

let fence = (~counted=true, counts): Reventless.DcbFenceCount.fence => {
  tag: student,
  counted,
  counts: Dict.fromArray(counts),
}

let read = events => {
  let seen = Dict.make()
  events->Array.forEach(((eventType, tags)) =>
    Reventless.DcbFenceCount.countRead(seen, clauses, ~eventType, ~tags)
  )
  seen
}

describe("DcbFenceCount", () => {
  testSync("only the cross-partition clause is checked", () => {
    expect(clauses->Array.map(c => c.tag.key))->toEqual(["studentId"])
  })

  testSync("reading what was counted falls short of nothing", () => {
    let seen = read([
      ("StudentSubscribed", [course, student]),
      ("StudentSubscribed", [{key: "courseId", value: "C2"}, student]),
    ])
    expect(
      Reventless.DcbFenceCount.shortfalls([fence([("StudentSubscribed", 2)])], clauses, seen),
    )->toEqual([])
  })

  testSync("an event the index missed is a shortfall of its type", () => {
    let seen = read([("StudentSubscribed", [course, student])])
    expect(
      Reventless.DcbFenceCount.shortfalls(
        [fence([("StudentSubscribed", 2), ("StudentLeft", 1)])],
        clauses,
        seen,
      ),
    )->toEqual([
      {Reventless.DcbFenceCount.tag: student, eventType: "StudentSubscribed", read: 1, counted: 2},
      {tag: student, eventType: "StudentLeft", read: 0, counted: 1},
    ])
  })

  testSync("an event of another tag value does not count", () => {
    let seen = read([("StudentSubscribed", [course, {key: "studentId", value: "S2"}])])
    expect(seen->Dict.toArray)->toEqual([])
  })

  testSync("a fence not yet counted proves nothing", () => {
    expect(
      Reventless.DcbFenceCount.shortfalls(
        [fence(~counted=false, [("StudentSubscribed", 5)])],
        clauses,
        read([]),
      ),
    )->toEqual([])
  })

  testSync("reading more than was counted is no shortfall", () => {
    // A write after the fence was read: the append's own check sees it.
    let seen = read([("StudentSubscribed", [student]), ("StudentSubscribed", [student])])
    expect(
      Reventless.DcbFenceCount.shortfalls([fence([("StudentSubscribed", 1)])], clauses, seen),
    )->toEqual([])
  })
})
