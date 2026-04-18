/** AppSync_EventsApi — creates an IAM-authenticated AppSync Events (Pub/Sub) API
    with a `default` channel namespace.

    This is a companion to the AppSync GraphQL API. Sources A and B push
    real-time events here; clients subscribe to channels such as
    `/default/catalog_Product`.

    Usage (in platform/plugin builder after the GraphQL API is created):
      let eventsApi = AppSync_EventsApi.make(~name="DomainEventsApi", ~opts)

    Then pass `eventsApi` to:
      StateTopic_AppSync.make(~eventsApi, ...)
      EventLogSubscription_AppSync.make(~eventsApi, ...)
*/

module Api = PulumiAws.AwsNative.AppSync.Api
module ChannelNamespace = PulumiAws.AwsNative.AppSync.ChannelNamespace

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
  // `/default/{channelName}` in both Lambda publish calls and client subscriptions.
  let defaultNamespace = ChannelNamespace.make(
    ~name=name ++ "DefaultNS",
    ~args={
      apiId: api.apiId->Pulumi.Output.asInput,
      name: "default"->Pulumi.Input.make,
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
