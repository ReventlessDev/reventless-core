// Regression tests for CommandPublisher (plan A7).
//
// Two bugs made the buffered publisher silently lose commands:
//   - send() used the non-mutating `toSpliced`, so the buffer never drained and
//     the wrong slice was published.
//   - flush()'s in-flight arm looped on a dead condition and never sent.
//   - clear() removed only the first buffered command instead of truncating.
//
// These tests drive the functor with a capturing publishCommands and assert the
// buffer flushes in order and clear() empties it.

open JestGlobals

S.enableJson()

let published: ref<array<Reventless.Message.commandJson>> = ref([])

module TestSpec = {
  @schema let name = "TestCmd"
  @schema type command = {value: int}
}

module TestConfig = {
  let user = "tester"
  let publishCommands: Task.publishCommands = (_name, cmds) => {
    published := published.contents->Array.concat(cmds)
    Promise.resolve()
  }
  let mode = CommandPublisher.SendAllInOneChunk
}

module Pub = CommandPublisher.Make(TestSpec, TestConfig)

describe("CommandPublisher", () => {
  testPromise("flush sends all buffered commands in order and drains the buffer", async () => {
    published := []
    Pub.publish("id1", {value: 1})
    Pub.publish("id2", {value: 2})
    await Pub.flush()
    let ids = published.contents->Array.map((c: Reventless.Message.commandJson) => c.id)
    expect(ids)->toEqual(["id1", "id2"])
    // Buffer drained: a second flush sends nothing more.
    published := []
    await Pub.flush()
    expect(published.contents->Array.length)->toBe(0)
  })

  testPromise("clear truncates the whole buffer so nothing is later published", async () => {
    published := []
    Pub.publish("id3", {value: 3})
    Pub.publish("id4", {value: 4})
    Pub.clear()
    await Pub.flush()
    expect(published.contents->Array.length)->toBe(0)
  })
})
