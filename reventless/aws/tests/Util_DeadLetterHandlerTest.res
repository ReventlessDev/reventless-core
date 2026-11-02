open JestGlobals

module H = Util_DeadLetterHandler

// A dead letter writes one full line on its first delivery here and a short one on every
// redelivery. A message moved here by a redrive policy keeps its receive count, so its first
// delivery reports `maxReceiveCount + 1`; reading only 1 as first meant the full line was
// never written for any of them.

let recordWith = (~receiveCount: int): H.record => {
  messageId: "m-1",
  body: `{"command":{"TAG":"Heartbeat"}}`,
  attributes: Dict.fromArray([
    ("ApproximateReceiveCount", Int.toString(receiveCount)),
    ("DeadLetterQueueSourceArn", "arn:aws:sqs:eu-west-1:1:CmdTopic"),
  ]),
}

let isItem = line => line->String.startsWith("DEAD LETTER ITEM:")

describe("the dead-letter handler's line", () => {
  testSync("is the full one when a redriven message first arrives", () => {
    let line = H.lineOf(recordWith(~receiveCount=H.maxReceiveCount + 1))
    expect((isItem(line), line->String.includes("kind=Heartbeat")))->toEqual((true, true))
  })

  testSync("is the full one for a message sent here directly", () =>
    expect(isItem(H.lineOf(recordWith(~receiveCount=1))))->toBe(true)
  )

  testSync("is the short one on a redelivery", () => {
    let line = H.lineOf(recordWith(~receiveCount=H.maxReceiveCount + 2))
    expect((
      line->String.startsWith("DEAD LETTER REDELIVERY:"),
      line->String.includes("kind="),
    ))->toEqual((true, false))
  })

  testSync("names an unreadable body's kind unknown, and never writes the body", () => {
    let line = H.lineOf({
      messageId: "m-2",
      body: "not json, about a person",
      attributes: Dict.make(),
    })
    expect((
      line->String.includes("kind=unknown"),
      line->String.includes("about a person"),
    ))->toEqual((true, false))
  })
})

describe("the dead-letter handler", () => {
  test("fails on purpose, so the messages stay on the queue", async () => {
    let failed = switch await H.handler({records: [recordWith(~receiveCount=6)]}) {
    | () => false
    | exception _ => true
    }
    expect(failed)->toBe(true)
  })

  // The function ships the compiled file alone, so it must import nothing.
  testSync("compiles to a file that imports nothing", () => {
    let text = NodeFs.readFileSync(
      NodePath.join([
        NodePath.dirname(NodeUrl.fileURLToPath(%raw("import.meta.url"))),
        "..",
        "src",
        "util",
        "Util_DeadLetterHandler.res.mjs",
      ]),
    )
    expect(
      text
      ->String.split("\n")
      ->Array.some(l => l->String.startsWith("import ") || l->String.includes("require(")),
    )->toBe(false)
  })
})
