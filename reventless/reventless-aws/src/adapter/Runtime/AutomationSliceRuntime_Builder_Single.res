module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledAutomationSliceInfo = {
  specModulePath: string,
  queryDbTableName: Pulumi.Output.t<string>,
}

let bundledInfos: dict<bundledAutomationSliceInfo> = Dict.make()

let dcbQueueUrlRef: ref<option<Pulumi.Output.t<string>>> = ref(None)
let setDcbQueueUrl = url => dcbQueueUrlRef := Some(url)

let registerAutomationSlice = (
  ~name,
  ~specModulePath,
  ~queryDbTableName,
) =>
  bundledInfos->Dict.set(name, {specModulePath, queryDbTableName})

include ProjectionRuntime_Builder_Single.Make({
  type info = bundledAutomationSliceInfo
  type registration = Util_EntryPoint.automationSliceRegistration

  let name = "AllAutomationSlices"
  let builderName = "AutomationSliceRuntime_Builder_Single"
  let factoryModulePath =
    "@reventlessdev/reventless-aws/src/adapter/Runtime/AutomationSliceHandlerFactory.mjs"
  let infos = bundledInfos

  let processHandler = (~envVars, ~info, ~indexStr, ~sourceUrnEnvVar) => {
    let tableEnvVar = `HANDLER_${indexStr}_TABLE`
    let dcbQueueUrlEnvVar = `HANDLER_${indexStr}_DCB_QUEUE_URL`
    envVars->Dict.set(tableEnvVar, info.queryDbTableName->Pulumi.Output.asInput)
    let dcbQueueUrl = switch dcbQueueUrlRef.contents {
    | Some(url) => url
    | None => Pulumi.Output.make("NOT_AVAILABLE")
    }
    envVars->Dict.set(dcbQueueUrlEnvVar, dcbQueueUrl->Pulumi.Output.asInput)
    {
      Util_EntryPoint.specModulePath: info.specModulePath,
      queryDbTableEnvVar: tableEnvVar,
      dcbQueueUrlEnvVar,
      sourceUrnEnvVar,
    }
  }

  let generateEntryPoint = (name, handlers, factoryModule, requestContextModule) =>
    Util_EntryPoint.generateAutomationSliceEntryPoint({
      name,
      handlers,
      factoryModule,
      requestContextModule,
    })
})
