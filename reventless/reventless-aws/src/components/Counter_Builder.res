module type Config = {
  let specModulePath: string
  let mappingsModulePath: string
  let publishQueueUrl: Pulumi.Output.t<string>
}

module Make = (
  Api: {
    let api: Types.AppSync.api
    let apiRole: Types.AppSync.role
  },
  Config: Config,
) => {
  module Inner = ReventlessCore.Counter_Builder.Make(
    QueryDbStorage_DynamoDbStream,
    Api,
    CounterHandler_DynamoDbStream,
  )

  type component = Inner.component

  let make = (~name, ~jsonEventsHandler, ~ttl=?, ~opts=?) => {
    CounterHandler_DynamoDbStream.registerCounter(
      ~counterName=name->ReventlessCore.ComponentType.name(ReventlessCore.Counter.componentType),
      ~specModulePath=Config.specModulePath,
      ~mappingsModulePath=Config.mappingsModulePath,
      ~publishQueueUrl=Config.publishQueueUrl,
    )

    Inner.make(~name, ~jsonEventsHandler, ~ttl?, ~opts?)
  }

  let outputs = Inner.outputs
  let operations = Inner.operations
}
