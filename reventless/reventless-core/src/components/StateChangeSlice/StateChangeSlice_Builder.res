let log = Logger.fromEnv()

module Make = (
  Spec: Reventless.StateChangeSlice.Spec,
  Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
): StateChangeSlice.T => {
  module Spec = Spec
  module Behavior = Behavior
  let isAsync = false
  type component = StateChangeSlice.component
  module Callback = StateChangeSlice_Callback.Make(Spec, Behavior)

  let makeJsonHandler = (~tagKeysByEventType, ~crossPartitionTagKeys, dcbEventLogOps: DcbEventLog.operations) => {
    let handler: CommandTopic.jsonCommandsHandler = stream => {
      let decodedStream =
        stream
        ->Stream.mapEffect(({ReventlessInfra.CommandTopic.reference: reference, command: json}) =>
          Effect.sync(() =>
            switch json->Message.decodeCommand'(Reventless.Id.String.schema, Spec.commandSchema) {
            | command' => Some({ReventlessInfra.CommandTopic.reference, command: command'})
            | exception err =>
              let commandStr = json->JSON.stringify
              log.error(
                ~comp=`StateChangeSlice(${Spec.name})`,
                ~data=err->JSON.stringifyAny->Option.getOr("")->JSON.Encode.string,
                `Couldn't decode command ${commandStr}`,
              )
              None
            }
          )
        )
        ->Stream.flatMap(opt =>
          switch opt {
          | Some(v) => Stream.fromIterable([v])
          | None => Stream.empty
          }
        )
      Callback.handleCommands(~tagKeysByEventType, ~crossPartitionTagKeys, dcbEventLogOps, decodedStream)
    }
    handler
  }

  let construct = (
    ~dcbEventLog: DcbEventLog.component,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~tagKeysByEventType,
    ~crossPartitionTagKeys,
    self,
    _name,
  ) => {
    let commandSchema: S.t<unknown> = Spec.commandSchema->S.castToUnknown
    let commandTypeNames = CommandTopic.extractTypeNamesFromSchema(commandSchema)

    let _ =
      dcbEventLog
      ->Component.operations
      ->Pulumi.Output.apply(dcbEventLogOps => {
        let jsonHandler = makeJsonHandler(~tagKeysByEventType, ~crossPartitionTagKeys, dcbEventLogOps)
        CommandTopic.registerHandler(
          ~schema=commandSchema,
          ~handler=jsonHandler,
          ~typeNames=commandTypeNames,
        )
      })

    self->Component.setOperations(
      publishJsons->Pulumi.Output.apply(publishJsons => {
        let ops: StateChangeSlice.operations = {publishJsons: publishJsons}
        ops
      }),
    )
    let outputs: StateChangeSlice.outputs = {
      resources: (dcbEventLog->Component.outputs).resources,
    }
    self->Component.setOutputs(outputs)
  }

  let make = (
    ~dcbEventLog,
    ~publishJsons,
    ~tagKeysByEventType=Dict.make(),
    ~crossPartitionTagKeys=[],
    ~opts=?,
  ): StateChangeSlice.component =>
    Component.make(
      ~componentType=StateChangeSlice.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~dcbEventLog, ~publishJsons, ~tagKeysByEventType, ~crossPartitionTagKeys, ...),
      ~opts,
    )
}
