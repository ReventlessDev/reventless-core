// Response-envelope tests for InboundTranslationSlice mutations.
//
// The field is declared `CommandResult!`, an abstract type. A resolver invoked
// directly cannot show whether the value it returns actually resolves to a union
// member — only a real execution can, and until one existed every inbound
// mutation came back as `Abstract type "CommandResult" must resolve to an Object
// type at runtime` even though the translation had succeeded.
//
// So these tests compose the schema the way the running platform does
// (DomainGraphQL_Server.composeSchema) and execute a document against it, then
// assert on the FULL envelope — `errors` as well as `data`.
//
// The resolver is driven by a real InboundTranslationSlice_Callback, so the
// mutation exercises parse -> translate -> publish -> encode end to end.

@@warning("-44")

open JestGlobals
open InboundTranslationSliceFixtures

module PaymentWebhookTranslation = {
  let translate = PaymentWebhookSpec.translate
  let moduleUrl = PaymentWebhookSpec.moduleUrl
}

module Callback = ReventlessCore.InboundTranslationSlice_Callback.Make(
  PaymentWebhookSpec,
  PaymentWebhookTranslation,
)

// Registered inside a plugin scope, not the platform one: a plugin bucket's
// document is validated standalone before the cross-plugin merge, so this also
// pins that the inbound path registers the CommandResult union itself rather
// than borrowing a registration from a sibling command handler.
let scope = "Payments"
let fieldName = "Payments_PaymentWebhook"

let published: ref<array<Reventless.Message.commandJson>> = ref([])

let publishJsons: ReventlessInfra.CommandTopic.publishJsons = async cmds =>
  published.contents = published.contents->Array.concat(cmds)

let selection = `__typename
  ... on CommandAccepted { msgId entityId eventCount }
  ... on CommandRejected { msgId errorCode errorDetail }`

let runMutation = async (~status: string) => {
  let source = `mutation {
    r: ${fieldName}(paymentId: "pay-1", orderId: "ord-1", status: "${status}") { ${selection} }
  }`
  await GraphqlYoga.graphql({
    "schema": DomainGraphQL_Server.composeSchema(),
    "source": source,
    "contextValue": JSON.Encode.null,
  })
}

let errorMessages = (result: GraphqlYoga.executionResult): array<string> =>
  result.errors
  ->Option.getOr([])
  ->Array.map(e => e->JsExn.message->Option.getOr("unknown error"))

let payload = (result: GraphqlYoga.executionResult): JSON.t =>
  result.data
  ->Option.getOr(JSON.Encode.null)
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("r"))
  ->Option.getOr(JSON.Encode.null)

let str = (node: JSON.t, key: string): option<string> =>
  node->JSON.Decode.object->Option.flatMap(d => d->Dict.get(key))->Option.flatMap(JSON.Decode.string)

let num = (node: JSON.t, key: string): option<float> =>
  node->JSON.Decode.object->Option.flatMap(d => d->Dict.get(key))->Option.flatMap(JSON.Decode.float)

describe("InboundTranslationSlice mutation — response envelope", () => {
  beforeEach(() => {
    DomainGraphQL_Server.asInterface.reset()
    published.contents = []
    Callback.auditLog->Dict.keysToArray->Array.forEach(k => Callback.auditLog->Dict.delete(k))

    DomainGraphQL_Server.setScope(scope)
    InboundTranslationResolvers_GraphQL.register(
      ~fieldName,
      ~externalInputSchema=PaymentWebhookSpec.externalInputSchema->S.castToUnknown,
      ~server=DomainGraphQL_Server.asInterface,
    )
    DomainGraphQL_Server.resetScope()

    InboundTranslationResolvers_GraphQL.bindReceive(
      ~fieldName,
      ~receive=inputJson => Callback.receive(publishJsons, inputJson),
    )
  })

  testPromise("a successful translation resolves as CommandAccepted, with no errors", async () => {
    let result = await runMutation(~status="completed")

    expect(errorMessages(result))->toEqual([])

    let node = payload(result)
    expect(node->str("__typename"))->toEqual(Some("CommandAccepted"))
    expect(node->str("entityId"))->toEqual(Some("ord-1"))
    expect(node->num("eventCount"))->toEqual(Some(1.0))

    // msgId is the audit-row key, so the caller can look the request up.
    let msgId = node->str("msgId")->Option.getOr("")
    expect(Callback.auditLog->Dict.get(msgId)->Option.isSome)->toBe(true)

    expect(published.contents->Array.length)->toBe(1)
  })

  testPromise("a rejected translation resolves as CommandRejected, with no errors", async () => {
    let result = await runMutation(~status="pending")

    expect(errorMessages(result))->toEqual([])

    let node = payload(result)
    expect(node->str("__typename"))->toEqual(Some("CommandRejected"))
    expect(node->str("errorCode"))->toEqual(Some("TranslationFailed"))
    expect(node->str("errorDetail"))->toEqual(Some("Unknown payment status: pending"))

    let msgId = node->str("msgId")->Option.getOr("")
    switch Callback.auditLog->Dict.get(msgId) {
    | Some(row) => expect(row.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Failure)
    | None => expect(true)->toBe(false)
    }

    expect(published.contents->Array.length)->toBe(0)
  })

  testSync("the mutation field is typed CommandResult!", () => {
    let fieldLine =
      DomainGraphQL_Server.asInterface.buildSdl()
      ->String.split("\n")
      ->Array.find(line => line->String.includes(fieldName))
    expect(fieldLine->Option.map(l => l->String.endsWith(": CommandResult!")))->toEqual(Some(true))
  })
})
