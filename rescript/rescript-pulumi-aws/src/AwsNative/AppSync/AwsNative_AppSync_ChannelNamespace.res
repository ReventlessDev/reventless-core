/** @pulumi/aws-native/appsync/ChannelNamespace — AppSync Events channel namespace.
    A channel namespace groups channels within an AppSync Events API.
    The conventional namespace for platform-generated events is `default`.
    Channels within the namespace are addressed as `/default/{channelName}`.
    See: https://www.pulumi.com/registry/packages/aws-native/api-docs/appsync/channelnamespace
*/

type authMode = {
  authType?: Pulumi.Input.t<string>,
}

type t = {
  apiId: Pulumi.Output.t<string>,
  channelNamespaceArn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
}

// ── OnPublish / OnSubscribe handler bindings ──────────────────────────────────
//
// AppSync Events namespaces optionally run handlers per published message
// and/or per subscribe attempt. `codeHandlers` carries a JS module body that
// exports `onPublish`/`onSubscribe`; `handlerConfigs` chooses the behavior
// (CODE = APPSYNC_JS runtime, DIRECT = Lambda-only) and points the integration
// at a NONE-typed data source (for CODE) or a Lambda-backed data source.

/** Integration behavior for a handler. */
let handlerBehaviorCode: string = "CODE"
let handlerBehaviorDirect: string = "DIRECT"

/** Lambda invocation type for `DIRECT`/`CODE`+`lambdaConfig` integrations. */
let invokeTypeRequestResponse: string = "REQUEST_RESPONSE"
let invokeTypeEvent: string = "EVENT"

type lambdaConfigArgs = {
  /** `"REQUEST_RESPONSE"` (sync) or `"EVENT"` (fire-and-forget). */
  invokeType: Pulumi.Input.t<string>,
}

type integrationArgs = {
  /** Name of an AppSync data source on the same Events API. Required by
      CloudFormation even for `CODE` behavior — typically a NONE-typed data
      source created by the caller. */
  dataSourceName: Pulumi.Input.t<string>,
  /** Required when invoking a Lambda; pair with `dataSourceName` pointing at
      the Lambda data source. */
  lambdaConfig?: Pulumi.Input.t<lambdaConfigArgs>,
}

type handlerConfigArgs = {
  /** Use one of `handlerBehaviorCode` / `handlerBehaviorDirect`. */
  behavior: Pulumi.Input.t<string>,
  integration: Pulumi.Input.t<integrationArgs>,
}

type handlerConfigsArgs = {
  onPublish?: Pulumi.Input.t<handlerConfigArgs>,
  onSubscribe?: Pulumi.Input.t<handlerConfigArgs>,
}

type args = {
  /** The AppSync Events API ID this namespace belongs to. Required. */
  apiId: Pulumi.Input.t<string>,
  /** Namespace name. Defaults to Pulumi resource name. Use `"default"`. */
  name?: Pulumi.Input.t<string>,
  /** Auth modes for publish operations. Defaults to API-level auth. */
  publishAuthModes?: Pulumi.Input.t<array<Pulumi.Input.t<authMode>>>,
  /** Auth modes for subscribe operations. Defaults to API-level auth. */
  subscribeAuthModes?: Pulumi.Input.t<array<Pulumi.Input.t<authMode>>>,
  /** JS module body exporting `onPublish(ctx)` and/or `onSubscribe(ctx)`.
      Selected for invocation per the `handlerConfigs.*.behavior` field. */
  codeHandlers?: Pulumi.Input.t<string>,
  /** Routing config for the `onPublish`/`onSubscribe` handlers. */
  handlerConfigs?: Pulumi.Input.t<handlerConfigsArgs>,
}

@module("@pulumi/aws-native") @scope("appsync") @new
external make: (
  ~name: string,
  ~args: args,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) => t = "ChannelNamespace"
