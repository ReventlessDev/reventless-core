module type Spec = {
  let pluginDefinition: Pulumi.Output.t<ReventlessSpec.Plugin.pluginDefinition>
  let connectPluginExtension: Extension.component
  let extensionPointsOutputs: array<ReventlessSpec.ExtensionPoint.outputs>
  let extensionsOutputs: array<Extension.outputs>
}

module Make = (Spec: Spec) => {
  let serviceNameToComponent = (components, getServiceNames) => {
    let dict = Js.Dict.empty()
    components->Belt.Array.forEach(component =>
      component
      ->getServiceNames
      ->Belt.Array.forEach(serviceName =>
        switch dict->Js.Dict.get(serviceName) {
        | Some(mappedExtensionPoints) =>
          Js.Dict.set(dict, serviceName, mappedExtensionPoints->Belt.Array.concat([component]))
        | None => Js.Dict.set(dict, serviceName, [component])
        }
      )
    )
    dict
  }

  let incomingServiceNameToPluginConnectExtensionsMapping = serviceNameToComponent(
    [Spec.connectPluginExtension->Component.extractOutputs],
    extension => [extension.extensionPointName],
  )
  let serviceNameToExtensionPointsMapping = serviceNameToComponent(
    Spec.extensionPointsOutputs,
    extensionPoint => extensionPoint.aggregateNames,
  )
  let outgoingServiceNameToExtensionsMapping = serviceNameToComponent(
    Spec.extensionsOutputs,
    extension => extension.aggregateNames,
  )
  let incomingServiceNameToExtensionsMapping = serviceNameToComponent(
    Spec.extensionsOutputs,
    extension => [extension.extensionPointName],
  )

  let handleEvent = async (event'Json, dict, getEventHandler) => {
    let pluginDefinition = Spec.pluginDefinition->Pulumi.Output.get

    await event'Json
    ->Message.serviceNameOfMsg
    ->Belt.Option.flatMap(serviceName => dict->Js.Dict.get(serviceName))
    ->Belt.Option.mapWithDefault(Js.Promise.resolve(), async components => {
      await components
      ->Belt.Array.map(component => getEventHandler(component)(event'Json, pluginDefinition))
      ->Js.Promise.all
      ->Util.Promise.toUnit
    })
  }

  let detectUnhandledEvent = event'Json =>
    event'Json
    ->Message.serviceNameOfMsg
    ->Belt.Option.mapWithDefault((), serviceName =>
      switch (
        serviceNameToExtensionPointsMapping->Js.Dict.get(serviceName),
        incomingServiceNameToExtensionsMapping->Js.Dict.get(serviceName),
        outgoingServiceNameToExtensionsMapping->Js.Dict.get(serviceName),
      ) {
      | (None, None, None) => Js.log("No mapping matches service name")
      | _ => ()
      }
    )

  let eventsHandler = events'Json => {
    let pluginDefinition = Spec.pluginDefinition->Pulumi.Output.get
    let id = pluginDefinition.id
    let count = events'Json->Belt.Array.size
    events'Json
    ->Belt.Array.mapWithIndex(async (idx, event'Json) => {
      let idx = idx + 1
      event'Json->Logger.logEvent'Json(
        `Plugin ${id} eventsHandler: incoming event ${idx->Belt.Int.toString}/${count->Belt.Int.toString}:`,
      )
      detectUnhandledEvent(event'Json)
      switch await handleEvent(
        event'Json,
        incomingServiceNameToPluginConnectExtensionsMapping,
        extension => extension.incomingEventHandler,
      ) {
      | _ =>
        [
          event'Json->handleEvent(serviceNameToExtensionPointsMapping, extensionPoint =>
            extensionPoint.outgoingEventHandler
          ),
          event'Json->handleEvent(outgoingServiceNameToExtensionsMapping, extension =>
            extension.outgoingEventHandler
          ),
          event'Json->handleEvent(incomingServiceNameToExtensionsMapping, extension =>
            extension.incomingEventHandler
          ),
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
    ->Belt.Array.concat([
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
