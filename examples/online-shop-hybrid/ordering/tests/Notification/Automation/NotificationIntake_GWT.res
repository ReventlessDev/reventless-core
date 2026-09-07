// The graft's rule table, which is where this host's occurrences are given a
// kind and a wording. It is data now, so a typo in a category key or a template
// compiles perfectly and sends the wrong thing — these scenarios are what makes
// that loud.

let testContext: Reventless.AutomationSlice.context = {
  environment: "test",
  platformName: "test",
  pluginName: "ordering",
  sliceName: "NotificationIntake",
}

module NotificationIntakeSlice = {
  include NotificationIntake
  type consumedEvent = NotificationIntake_Automation.FromOrderingDcb.sourceEvent
  let consumedEventSchema = NotificationIntake_Automation.FromOrderingDcb.sourceEventSchema

  let collect = e =>
    NotificationIntake_Automation.FromOrderingDcb.collect(e, ~sourceId="", testContext)
  let resolve = NotificationIntake_Automation.FromOrderingDcb.resolve
  let process = NotificationIntake_Automation.process
}

module Rule = TraitNotification.Notification_Rule

@@reventless.gwt

// One row of the shape every rule's paths read, so a rule nobody wrote a
// scenario for is still checked.
let sample =
  ({ruleId: "confirm", recipientId: "c1", orderId: "o1"}: NotificationIntake.todoItem)
  ->Reventless.Util_Sury.toJson(NotificationIntake.todoItemSchema)

describe("NotificationIntake AutomationSlice", () => {
  // Every rule in the table, not only the two with scenarios below: a third one
  // added with a broken template would otherwise ship in silence.
  test("the whole table is sound — every template parses and every path resolves", () =>
    switch Rule.validate(NotificationIntake_Automation.defaultRules, ~sample) {
    | [] => ReventlessGwt.Outcome.pass
    | problems =>
      ReventlessGwt.Outcome.fail(
        EventsMismatch({expected: [], actual: problems->Array.map(JSON.Encode.string)}),
      )
    }
  )

  // The routing field is only worth as much as the refusal behind it. A digest
  // rule in a deployment with nothing to gather one is passed over by the relay
  // and picked up by nobody, so it has to be loud here rather than at the point
  // where a notification quietly fails to arrive.
  test("the table refuses a digest rule where nothing gathers one, and takes it otherwise", () => {
    let digestRule = {
      ...NotificationIntake_Automation.defaultRules->Array.getUnsafe(0),
      id: "daily",
      delivery: Rule.Digest({windowSeconds: 86400}),
    }
    switch (
      Rule.validate([digestRule], ~sample),
      Rule.validate([digestRule], ~digestRouted=true, ~sample),
    ) {
    | ([], _) =>
      ReventlessGwt.Outcome.fail(
        EventsMismatch({
          expected: ["a digest rule this deployment cannot route is refused"]->Array.map(
            JSON.Encode.string,
          ),
          actual: [],
        }),
      )
    | (_, []) => ReventlessGwt.Outcome.pass
    | (_, routed) =>
      ReventlessGwt.Outcome.fail(
        EventsMismatch({expected: [], actual: routed->Array.map(JSON.Encode.string)}),
      )
    }
  })

  test("collect: a placed order becomes one todo, keyed by its rule and the order", () =>
    givenEvent(OrderPlaced({orderId: "o1", customerId: "c1"}))
    ->whenCollect
    ->thenTodos([("confirm:o1", {ruleId: "confirm", recipientId: "c1", orderId: "o1"})])
  )

  // The reference is the row key of the delivery view, the TODO id here, and how
  // that row is resolved — so two occurrences of one order must be two keys.
  test("collect: a shipped order is a second todo under a second key", () =>
    givenEvent(OrderShipped({orderId: "o1", customerId: "c1"}))
    ->whenCollect
    ->thenTodos([("ship:o1", {ruleId: "ship", recipientId: "c1", orderId: "o1"})])
  )

  test("collect: an outcome is not an occurrence", () =>
    givenEvent(NotificationRequested({reference: "confirm:o1"}))->whenCollect->thenTodos([])
  )

  test("resolve: a deferred request closes its row like any other outcome", () =>
    givenEvent(NotificationDeferred({reference: "confirm:o1"}))
    ->whenResolve
    ->thenResolved(Some("confirm:o1"))
  )

  // The wording is rendered from the rule's template, so this is also the
  // assertion that `{{ orderId }}` reaches the sentence.
  test("process: the confirmation says what the table says it says", () =>
    givenTodo("confirm:o1", {ruleId: "confirm", recipientId: "c1", orderId: "o1"})
    ->whenProcess
    ->thenCommand(
      "c1",
      RequestNotification({
        recipientId: "c1",
        category: NotificationPreferences.OrderConfirmation,
        reference: "confirm:o1",
        subjectType: "Order",
        subjectRef: "o1",
        subject: "Your order o1 is confirmed",
        body: "Thanks — we have your order o1 and will let you know when it ships.",
        sourceId: "OrderingDcbEventLog:OrderPlaced",
        origin: NotificationPreferences.Default,
      }),
    )
  )

  // The kind is a key in the table and a variant in the slice, and the lookup
  // between them falls back to the first kind declared. This rule's kind is not
  // that one, so a mistyped key shows up here rather than in production.
  test("process: the shipping update earns its own kind and its own source", () =>
    givenTodo("ship:o1", {ruleId: "ship", recipientId: "c1", orderId: "o1"})
    ->whenProcess
    ->thenCommand(
      "c1",
      RequestNotification({
        recipientId: "c1",
        category: NotificationPreferences.ShippingUpdate,
        reference: "ship:o1",
        subjectType: "Order",
        subjectRef: "o1",
        subject: "Your order o1 is on its way",
        body: "Good news — order o1 has shipped.",
        sourceId: "OrderingDcbEventLog:OrderShipped",
        origin: NotificationPreferences.Default,
      }),
    )
  )

  // A row left over from a rule the deployment has dropped. Nothing to compose
  // from, so nothing is published — and the row stays Pending, since a `None`
  // from `process` spends no retry budget.
  test("process: a row naming a rule this build no longer has publishes nothing", () =>
    givenTodo("gone:o1", {ruleId: "gone", recipientId: "c1", orderId: "o1"})
    ->whenProcess
    ->thenNoCommand
  )
})
