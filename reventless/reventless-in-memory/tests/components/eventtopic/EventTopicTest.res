// Integration tests for EventTopic_Builder with in-memory publisher.

open AsyncTest
open AsyncTest.Expect
open EventTopicFixtures

describe("EventTopic (in-memory)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventTopic->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => reset())

  testPromise("publish sends event to bus subscribers", async () => {
    let ops = await eventTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let event' = makeEvent'("item-1", ItemEventTopicSpec.ItemPublished({name: "Widget"}))
    await ops.publish([event'])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("publish multiple events notifies subscribers for each", async () => {
    let ops = await eventTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let events = [
      makeEvent'("item-1", ItemEventTopicSpec.ItemPublished({name: "Widget"})),
      makeEvent'("item-2", ItemEventTopicSpec.ItemRemoved({id: "item-2"})),
    ]
    await ops.publish(events)
    expect(capturedEventCount.contents)->toBe(2)
  })

  testPromise("publish empty array does not notify subscribers", async () => {
    let ops = await eventTopic->ReventlessCore.Component.operations->TestRunner.resolve
    await ops.publish([])
    expect(capturedEventCount.contents)->toBe(0)
  })
})
