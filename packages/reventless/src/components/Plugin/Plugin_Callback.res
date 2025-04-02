type eventHandler = (Js.Json.t, ReventlessSpec.Plugin.pluginDefinition) => Js.Promise.t<unit>
type eventHandlersByService = dict<array<eventHandler>>

module type Spec = {
  let pluginDefinition: ReventlessSpec.Plugin.pluginDefinition
  let incomingConnectExtensionEventHandlers: eventHandlersByService
  let outgoingExtensionPointEventHandlers: eventHandlersByService
  let outgoingExtensionEventHandlers: eventHandlersByService
  let incomingExtensionEventHandlers: eventHandlersByService
}

module type T = {
  let handleJsonEvents: array<Js.Json.t> => Js.Promise.t<unit>
}

module Make = (Spec: Spec): T => {
  let handleEvent = async (eventJson', eventHandlersByService) =>
    await eventJson'
    ->Message.serviceNameOfMsg
    ->Belt.Option.flatMap(serviceName => eventHandlersByService->Js.Dict.get(serviceName))
    ->Belt.Option.mapWithDefault(Js.Promise.resolve(), async eventHandlers => {
      await eventHandlers
      ->Array.map(eventHandler => eventHandler(eventJson', Spec.pluginDefinition))
      ->Js.Promise.all
      ->Util.Promise.toUnit
    })

  let detectUnhandledEvent = eventJson' =>
    eventJson'
    ->Message.serviceNameOfMsg
    ->Belt.Option.mapWithDefault((), serviceName =>
      switch (
        Spec.outgoingExtensionPointEventHandlers->Js.Dict.get(serviceName),
        Spec.outgoingExtensionEventHandlers->Js.Dict.get(serviceName),
        Spec.incomingExtensionEventHandlers->Js.Dict.get(serviceName),
      ) {
      | (None, None, None) => Js.log("No mapping matches service name")
      | _ => ()
      }
    )

  let handleJsonEvents = eventsJson => {
    let id = Spec.pluginDefinition.id
    let count = eventsJson->Belt.Array.size
    eventsJson
    ->Array.mapWithIndex(async (eventJson', idx) => {
      let idx = idx + 1
      eventJson'->Logger.logJsonEvent(
        `Plugin ${id} handleJsonEvents: incoming event ${idx->Belt.Int.toString}/${count->Belt.Int.toString}:`,
      )
      detectUnhandledEvent(eventJson')
      switch await eventJson'->handleEvent(Spec.incomingConnectExtensionEventHandlers) {
      | _ =>
        [
          eventJson'->handleEvent(Spec.outgoingExtensionPointEventHandlers),
          eventJson'->handleEvent(Spec.outgoingExtensionEventHandlers),
          eventJson'->handleEvent(Spec.incomingExtensionEventHandlers),
        ]->Js.Promise.all
      }
    })
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }
}

let addStatement = (policy: AwsSdk.IAM.Policy.t, sid, queueArn, topicArn) => {
  let newStatements =
    policy.statement
    ->Belt.Array.keep(statement => statement.sid != sid)
    ->Array.concat([
      {
        AwsSdk.IAM.Policy.sid,
        effect: "Allow",
        principal: "*",
        action: "sqs:SendMessage",
        resource: queueArn,
        condition: {arnEquals: topicArn},
      },
    ])
  Js.log(`addStatement: adding 1 statement with Sid ${sid}`)
  {
    AwsSdk.IAM.Policy.version: policy.version,
    id: policy.id,
    statement: newStatements,
  }
}
let removeStatement = (policy: AwsSdk.IAM.Policy.t, sid) => {
  let statements = policy.statement
  let newStatements = statements->Belt.Array.keep(statement => statement.sid != sid)
  let removedStatements = statements->Belt.Array.length - newStatements->Belt.Array.length
  Js.log(
    `removeStatement: removing ${removedStatements->Belt.Int.toString} statement(s) with Sid ${sid}`,
  )
  {
    AwsSdk.IAM.Policy.version: policy.version,
    id: policy.id,
    statement: newStatements,
  }
}

let _addPermission = async (sid, eventCollector, eventTopic) =>
  switch await AwsSdk.SQS.getQueuePolicy(eventCollector) {
  | policy =>
    eventCollector->AwsSdk.SQS.setQueuePolicy(policy->addStatement(sid, eventCollector, eventTopic))
  }

let _removePermission = async (sid, eventCollector) =>
  switch await AwsSdk.SQS.getQueuePolicy(eventCollector) {
  | policy => eventCollector->AwsSdk.SQS.setQueuePolicy(policy->removeStatement(sid))
  }
