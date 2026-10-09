// OutboundTranslation_GWT.FromSlice: the slice's real `translate`, run against
// recording capability fakes, and statuses counted as the runtime counts them.

module Welcome = {
  let name = "Welcome"
  let moduleUrl = ""

  @schema
  type consumedEvent = Registered({customerId: string, email: string})

  @schema
  type outboundItem = {email: string}

  @schema
  type inboundCommand = MarkWelcomed({customerId: string}) | MarkUnreachable({customerId: string})

  let maxRetries = 2
  let heartbeatInterval = 60
  let targetName = Some("Customer")
  let sourceNames = []
  let externalSystem = None
  let capabilityNeeds = []
  let traits = []
}

module Welcome_Translation = {
  let moduleUrl = ""

  let collect = (event, ~sourceId) =>
    switch event {
    | Welcome.Registered({email, _}) => [(sourceId, ({email: email}: Welcome.outboundItem))]
    }

  let translate = async (
    id,
    item: Welcome.outboundItem,
    ~capabilities: Reventless.Capabilities.t,
  ) =>
    switch await capabilities.messaging.send(
      ~recipient=ToEmail(item.email),
      ~message={subject: "Welcome", body: "Hello"},
    ) {
    | Ok(_) => Ok(Some((id, Welcome.MarkWelcomed({customerId: id}))))
    | Error(failure) => Error(failure->Reventless.Messaging.failureReason)
    }

  let onExhausted = (id, _item, ~lastError as _) => Some((
    id,
    Welcome.MarkUnreachable({customerId: id}),
  ))
}

open Welcome
include OutboundTranslation_GWT.FromSlice(Welcome, Welcome_Translation)

let down = Capabilities_Fake.make(
  ~send=async (~recipient as _, ~message as _) => Error(Unavailable("smtp down")),
  (),
)

let welcome: Capabilities_Fake.call = Sent({
  recipient: ToEmail("a@b.c"),
  message: {subject: "Welcome", body: "Hello"},
})

describe("OutboundTranslation_GWT.FromSlice", () => {
  testSync("collect keys by the source id", () =>
    givenEvent(Registered({customerId: "c1", email: "a@b.c"}))
    ->whenCollect(~sourceId="c1")
    ->thenTodos([("c1", {email: "a@b.c"})])
  )

  test("translate sends through the messaging capability", () =>
    givenTodo("c1", {email: "a@b.c"})->whenTranslated->thenSent([welcome])
  )

  test("translate answers with a command", () =>
    givenTodo("c1", {email: "a@b.c"})
    ->whenTranslated
    ->thenCommand("c1", MarkWelcomed({customerId: "c1"}))
  )

  test("a failed attempt leaves the row Failed", () =>
    givenTodo("c1", {email: "a@b.c"})
    ->givenCapabilities(down)
    ->whenTranslated
    ->thenTodoStatus("c1", #Failed)
  )

  test("#Pending still reads as #Failed", () =>
    givenTodo("c1", {email: "a@b.c"})
    ->givenCapabilities(down)
    ->whenTranslated
    ->thenTodoStatus("c1", #Pending)
  )

  test("maxRetries failed attempts abandon the row", () =>
    givenTodo("c1", {email: "a@b.c"})
    ->whenTranslateRetrying(async (_, _) => Error("down"))
    ->thenTodoStatus("c1", #Abandoned)
  )

  test("maxRetries attempts in all, as the runtime makes them", () =>
    givenTodo("c1", {email: "a@b.c"})
    ->whenTranslateRetrying(async (_, _) => Error("down"))
    ->thenRetryRecorded(2)
  )

  test("a throw is a failed attempt", () =>
    givenTodo("c1", {email: "a@b.c"})
    ->whenTranslateMocked(async (_, _) => JsError.throwWithMessage("boom"))
    ->thenTodoStatus("c1", #Failed)
  )

  test("exhausted: onExhausted is what the domain hears", () =>
    givenTodo("c1", {email: "a@b.c"})
    ->whenExhausted(~lastError="smtp down")
    ->thenCommand("c1", MarkUnreachable({customerId: "c1"}))
  )

  test("nothing sent when the slice is never translated", () =>
    givenTodo("c1", {email: "a@b.c"})->whenExhausted->thenNothingSent
  )
})
