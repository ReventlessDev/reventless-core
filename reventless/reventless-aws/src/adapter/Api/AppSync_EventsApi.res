/** AppSync_EventsApi — creates an IAM-authenticated AppSync Events (Pub/Sub) API
    with a `default` channel namespace.

    This is a companion to the AppSync GraphQL API. Sources A and B push
    real-time events here; clients subscribe to channels such as
    `/default/{topicRoot}/{entityKey}` — see `StateTopic_AppSync.res` for
    channel layout.

    Usage (in platform/plugin builder after the GraphQL API is created):
      let eventsApi = AppSync_EventsApi.make(~name="DomainEventsApi", ~opts)

    Then pass `eventsApi` to:
      StateTopic_AppSync.make(~eventsApi, ...)
      EventLogSubscription_AppSync.make(~eventsApi, ...)

    ## Subscribe-time authorization (extension hook)

    Downstream extensions (e.g. multi-tenancy) can gate WebSocket subscribes
    by calling `registerSubscribeAuth` BEFORE platform construction:

      AppSync_EventsApi.registerSubscribeAuth({
        codeHandlers: "export function onSubscribe(ctx) { ... }",
        dataSourceName: noneDs.name->Pulumi.Output.asInput,
      })

    The framework wires the namespace's `handlerConfigs.onSubscribe` to the
    provided JS code; the extension is responsible for creating the AppSync
    data source (typically NONE-typed) on the Events API. With no hook
    installed, subscribe goes through the API-level auth modes only
    (single-tenant open-core case).
*/

module Api = PulumiAws.AwsNative.AppSync.Api
module ChannelNamespace = PulumiAws.AwsNative.AppSync.ChannelNamespace

/** Configuration for the namespace's `onSubscribe` handler. The framework
    enforces this handler is called per subscribe attempt; the JS body decides
    whether to allow or deny by calling `util.unauthorized()`. */
type subscribeAuthConfig = {
  /** JS module body containing `export function onSubscribe(ctx) { ... }`.
      Runs in AppSync's APPSYNC_JS runtime per subscribe attempt. */
  codeHandlers: string,
  /** Name of an AppSync data source on this Events API. Required by
      CloudFormation even for `CODE` behavior — typically a NONE-typed data
      source the extension creates separately. */
  dataSourceName: Pulumi.Input.t<string>,
}

let subscribeAuthRef: ref<option<subscribeAuthConfig>> = ref(None)

/** Install the subscribe-time auth handler. Call before platform
    construction. Idempotent — calling twice keeps the most recent value. */
let registerSubscribeAuth = (config: subscribeAuthConfig) => {
  subscribeAuthRef.contents = Some(config)
}

/** Clear any installed subscribe-auth handler (testing / hot-reload). */
let clearSubscribeAuth = () => {
  subscribeAuthRef.contents = None
}

type t = {
  /** Full AppSync Events API output — carry this through the stack. */
  api: Api.t,
  /** The `default` channel namespace created on the API. */
  defaultNamespace: option<ChannelNamespace.t>,
}

/** Create an AppSync Events API with AWS_IAM auth + a `default` channel namespace.

    `name` is the Pulumi resource name prefix (e.g. `"DomainEventsApi"`).
    `opts` should set `parent` to the platform component resource. */
let make = (~name: string, ~opts: Pulumi.CustomResourceOptions.t): t => {
  let iamMode: Api.authMode = {authType: Api.awsIam->Pulumi.Input.make}
  let iamProvider: Api.authProvider = {authType: Api.awsIam->Pulumi.Input.make}

  let api = Api.make(
    ~name,
    ~args={
      eventConfig: (
        {
          authProviders: [iamProvider->Pulumi.Input.make]->Pulumi.Input.make,
          connectionAuthModes: [iamMode->Pulumi.Input.make]->Pulumi.Input.make,
          defaultPublishAuthModes: [iamMode->Pulumi.Input.make]->Pulumi.Input.make,
          defaultSubscribeAuthModes: [iamMode->Pulumi.Input.make]->Pulumi.Input.make,
        }: Api.eventConfigArgs
      )->Pulumi.Input.make,
    },
    ~opts=Some(opts),
  )

  // The `default` namespace is required — channels are addressed as
  // `/default/{topicRoot}/{entityKey}` in both Lambda publish calls and client
  // subscriptions. If an extension has installed a subscribe-auth handler via
  // `registerSubscribeAuth`, wire it as the namespace's `onSubscribe` handler.
  let subscribeAuth = subscribeAuthRef.contents
  let codeHandlersInput: option<Pulumi.Input.t<string>> =
    subscribeAuth->Option.map(c => c.codeHandlers->Pulumi.Input.make)
  let handlerConfigsInput: option<Pulumi.Input.t<ChannelNamespace.handlerConfigsArgs>> =
    subscribeAuth->Option.map(c => {
      ChannelNamespace.onSubscribe: {
        ChannelNamespace.behavior: ChannelNamespace.handlerBehaviorCode->Pulumi.Input.make,
        integration: {
          ChannelNamespace.dataSourceName: c.dataSourceName,
        }->Pulumi.Input.make,
      }->Pulumi.Input.make,
    }->Pulumi.Input.make)
  let defaultNamespace = ChannelNamespace.make(
    ~name=name ++ "DefaultNS",
    ~args={
      apiId: api.apiId->Pulumi.Output.asInput,
      name: "default"->Pulumi.Input.make,
      codeHandlers: ?codeHandlersInput,
      handlerConfigs: ?handlerConfigsInput,
    },
    ~opts=Some({...opts, parent: api->Pulumi.Resource.makeFromJs}),
  )

  {api, defaultNamespace: Some(defaultNamespace)}
}

/** HTTP endpoint URL for use as Lambda `APPSYNC_ENDPOINT` env var.
    Constructs `https://{dns.http}` from the raw domain name in the API output. */
let httpEndpoint = (eventsApi: t): Pulumi.Output.t<string> =>
  eventsApi.api.dns->Pulumi.Output.apply(dns =>
    "https://" ++ dns.http->Option.getOr("")
  )
