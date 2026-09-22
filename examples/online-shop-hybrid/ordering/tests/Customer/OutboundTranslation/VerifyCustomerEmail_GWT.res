// The issue-and-send half. What it decides is whether a challenge opens at all,
// and the order in which the two things it does have to happen.
//
// The secret is pinned rather than random, which is the reason the source is a
// capability: a suite cannot assert what a flow does with a value it cannot
// predict, and this file would otherwise be able to check only that *something*
// was sent.

module VerifyCustomerEmailSlice = {
  include VerifyCustomerEmail
  let collect = VerifyCustomerEmail_Translation.collect
}

@@reventless.gwt

module Outcome = ReventlessGwt.Outcome

let item: VerifyCustomerEmail.outboundItem = {customerId: "c1", email: "alice@x.y"}

// What the run put on the wire, in both directions: the bodies that went to the
// address, and the commands that reached the ledger.
let bodies: ref<array<string>> = ref([])
let issued: ref<array<string>> = ref([])

// A known secret and a hash obviously derived from it, so an assertion can name
// both. `hashed:` is not what the real backend computes — what matters is that
// whatever the source produced is what the ledger was told about.
let withSecrets = (~send): Reventless.Capabilities.t => {
  ...Reventless.Capabilities.none,
  secrets: Reventless.Secrets.fixed(~token="known-secret", ~hash=t => `hashed:${t}`),
  messaging: Reventless.Messaging.makeProvider(~emailAndSms=[Email], ~pushServices=[], ~send),
}

// No secret source at all: `Capabilities.none` refuses, and messaging is wired
// so the refusal cannot be mistaken for a mail problem.
let withoutSecrets = (~send): Reventless.Capabilities.t => {
  ...Reventless.Capabilities.none,
  messaging: Reventless.Messaging.makeProvider(~emailAndSms=[Email], ~pushServices=[], ~send),
}

let accepts = (~recipient as _, ~message: Reventless.Messaging.message) => {
  bodies := bodies.contents->Array.concat([message.body])
  Promise.resolve(Ok({Reventless.Messaging.ref: "ses-1"}))
}

let refuses = failure => (~recipient as _, ~message as _) => Promise.resolve(Error(failure))

// Records what reached the ledger, because the command carries an instant read
// from the clock and so cannot be compared whole.
let run = capabilities => {
  bodies := []
  issued := []
  async (id, item) => {
    let attempt = await VerifyCustomerEmail_Translation.translate(id, item, ~capabilities)
    switch attempt {
    | Ok(Some((_, IssueEmailChallenge({proofHash, email, purpose, _})))) =>
      issued := issued.contents->Array.concat([`${email}|${purpose}|${proofHash}`])
    | _ => ()
    }
    attempt
  }
}

let alsoThat = async (pending, ~expected, holds) =>
  switch await pending {
  | Error(_) as failed => failed
  | Ok() =>
    holds() ? Outcome.pass : Outcome.fail(TranslateError({expected, actual: Some("it did not")}))
  }

describe("VerifyCustomerEmail OutboundTranslationSlice", () => {
  // 🚨 The hash reaches the ledger and the secret does not. Everything else in
  // this competency assumes the log holds nothing that would answer a challenge.
  // scenario-id: 866cd8c0-c30b-4049-85e1-98359a252c49
  test("a sent challenge is opened against the hash, never the secret", () =>
    givenTodo("c1:alice@x.y", item)
    ->whenTranslateMocked(run(withSecrets(~send=accepts)))
    ->thenTodoStatus("c1:alice@x.y", #Completed)
    ->alsoThat(
      ~expected="the ledger is told alice@x.y|ContactChange|hashed:known-secret",
      () => issued.contents == ["alice@x.y|ContactChange|hashed:known-secret"],
    )
  )

  // scenario-id: dea4775c-9c1f-41e2-bd54-751b308c65cd
  test("the secret itself is what goes to the address", () =>
    givenTodo("c1:alice@x.y", item)
    ->whenTranslateMocked(run(withSecrets(~send=accepts)))
    ->thenTodoStatus("c1:alice@x.y", #Completed)
    ->alsoThat(
      ~expected="the message carries known-secret",
      () => bodies.contents->Array.some(body => body->String.includes("known-secret")),
    )
  )

  // 🚨 Send first, then record. A challenge opened against a message that never
  // went would be unanswerable, and the ledger would refuse to open a second one
  // for that address until the first lapsed.
  // scenario-id: 7de712d8-9930-41a2-977d-137639e38812
  test("a refused send opens no challenge", () =>
    givenTodo("c1:alice@x.y", item)
    ->whenTranslateMocked(
      run(withSecrets(~send=refuses(Reventless.Messaging.Refused("no such mailbox")))),
    )
    ->thenTodoStatus("c1:alice@x.y", #Pending)
  )

  // scenario-id: a04b17e9-d691-40d3-a431-894a1c75e9f2
  test("an unreachable provider opens no challenge either", () =>
    givenTodo("c1:alice@x.y", item)
    ->whenTranslateMocked(
      run(withSecrets(~send=refuses(Reventless.Messaging.Unavailable("smtp timeout")))),
    )
    ->thenTodoStatus("c1:alice@x.y", #Pending)
  )

  // A deployment with no secret source cannot prove anything. That is a gap in
  // the deployment rather than a verdict on the address, so nothing is recorded
  // and nothing is sent.
  // scenario-id: 70d4d062-1ba5-4d77-8e27-8af0f98d4bd8
  test("no secret source opens no challenge", () =>
    givenTodo("c1:alice@x.y", item)
    ->whenTranslateMocked(run(withoutSecrets(~send=accepts)))
    ->thenTodoStatus("c1:alice@x.y", #Pending)
  )

  // scenario-id: 29f4868d-b099-401f-9609-913f6c55bddf
  test("no secret source sends nothing either", () =>
    givenTodo("c1:alice@x.y", item)
    ->whenTranslateMocked(run(withoutSecrets(~send=accepts)))
    ->thenTodoStatus("c1:alice@x.y", #Pending)
    ->alsoThat(~expected="no message was sent", () => bodies.contents == [])
  )
})

describe("VerifyCustomerEmail collect", () => {
  // Keyed by entity and address together, so changing the address is new work
  // rather than work already done.
  testSync("registering and changing an address are separate work", () =>
    givenEvent(Registered({email: "alice@x.y", address: "1 Main"}))
    ->whenCollect(~sourceId="c1")
    ->thenTodos([("c1:alice@x.y", {customerId: "c1", email: "alice@x.y"})])
  )

  testSync("a changed address owes its own challenge", () =>
    givenEvent(EmailUpdated({email: "alice2@x.y"}))
    ->whenCollect(~sourceId="c1")
    ->thenTodos([("c1:alice2@x.y", {customerId: "c1", email: "alice2@x.y"})])
  )
})
