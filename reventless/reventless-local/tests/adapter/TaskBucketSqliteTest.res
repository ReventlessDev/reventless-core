// Round-trip test for TaskBucket_Sqlite put/get helpers.

open JestGlobals

describe("TaskBucket_Sqlite", () => {
  testPromise("put then get returns the stored body", async () => {
    let db = SqliteDriver.openDb(~path=":memory:")
    TaskBucket_Sqlite.put(~db, ~bucket="b1", ~key="k1", ~body="hello world")
    let got = TaskBucket_Sqlite.get(~db, ~bucket="b1", ~key="k1")
    expect(got)->toEqual(Some("hello world"))
    db->SqliteDriver.close
  })

  testPromise("put overwrites existing body at same (bucket, key)", async () => {
    let db = SqliteDriver.openDb(~path=":memory:")
    TaskBucket_Sqlite.put(~db, ~bucket="b1", ~key="k", ~body="one")
    TaskBucket_Sqlite.put(~db, ~bucket="b1", ~key="k", ~body="two")
    let got = TaskBucket_Sqlite.get(~db, ~bucket="b1", ~key="k")
    expect(got)->toEqual(Some("two"))
    db->SqliteDriver.close
  })

  testPromise("get returns None for missing key", async () => {
    let db = SqliteDriver.openDb(~path=":memory:")
    let got = TaskBucket_Sqlite.get(~db, ~bucket="empty", ~key="nope")
    expect(got)->toEqual(None)
    db->SqliteDriver.close
  })

  testPromise("body persists across a file reopen", async () => {
    let path = `/tmp/reventless-test-task-${Float.toString(Date.now())}.db`

    {
      let db = SqliteDriver.openDb(~path)
      TaskBucket_Sqlite.put(~db, ~bucket="audit", ~key="42", ~body="payload")
      db->SqliteDriver.close
    }

    let db2 = SqliteDriver.openDb(~path)
    let got = TaskBucket_Sqlite.get(~db=db2, ~bucket="audit", ~key="42")
    expect(got)->toEqual(Some("payload"))
    db2->SqliteDriver.close
  })
})
