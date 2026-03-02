module Make = (Spec: Reventless.StateChangeSlice.Spec): (
  StateChangeSlice.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec
) => {
  type dcbEvent = Spec.DcbEventLogSpec.event
  module Spec = Spec
  type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
  type component = StateChangeSlice.component
  module Callback = StateChangeSlice_Callback.Make(Spec)

  let makeJsonHandler = (dcbEventLogOps: DcbEventLog.operations<dcbEvent>) => {
    let handler: CommandTopic.jsonCommandsHandler = stream => {
      let decodedStream =
        stream
        ->Stream.mapEffect(({Reventless.CommandTopic.reference: reference, command: json}) =>
          Effect.sync(() =>
            switch json->Message.decodeCommand'(Reventless.Id.String.schema, Spec.commandSchema) {
            | command' => Some({Reventless.CommandTopic.reference, command: command'})
            | exception err =>
              let commandStr = json->JSON.stringify
              Logger.error(~loc=__LOC__, `Couldn't decode command ${commandStr}:`, err)
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
      Callback.handleCommands(dcbEventLogOps, decodedStream)
    }
    handler
  }

  let construct = (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    self,
    _name,
  ) => {
    let commandSchema: S.t<unknown> = Spec.commandSchema->S.castToUnknown
    let commandTypeNames = CommandTopic.extractTypeNamesFromSchema(commandSchema)

    let _ =
      dcbEventLog
      ->Component.operations
      ->Pulumi.Output.apply(dcbEventLogOps => {
        let jsonHandler = makeJsonHandler(dcbEventLogOps)
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

  let make = (~dcbEventLog, ~publishJsons, ~opts=?): StateChangeSlice.component =>
    Component.make(
      ~componentType=StateChangeSlice.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~dcbEventLog, ~publishJsons, ...),
      ~opts,
    )
}
