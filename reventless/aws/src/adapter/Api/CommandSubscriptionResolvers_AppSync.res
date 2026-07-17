// CommandSubscriptionResolvers_AppSync.res
// Source C: mutation-triggered subscription resolvers.
//
// Creates one AppSync Subscription-type resolver per command mutation field.
// The corresponding neutral SDL field (e.g. `onPlugin_Agg_Cmd`) is emitted by
// Plugin_SubscriptionSchema; its `@aws_subscribe(mutations: ["Plugin_Agg_Cmd"])`
// directive is appended at push time by AppSync_SdlDecorate from the
// fragment's subscription-source metadata. This resolver registers the handler
// on the Subscription type so AppSync can deliver the mutation return value
// to all matching subscribers automatically. AWS requires a dataSourceName
// on every resolver; we reuse the corresponding mutation's data source since
// UNIT subscription code never executes against it.

type api = Types.AppSync.api

let make = (
  ~api: api,
  ~mutationFields: array<string>,
  ~dataSourceName: Pulumi.Input.t<string>,
  ~opts: Pulumi.CustomResourceOptions.t,
) =>
  mutationFields->Array.forEach(field => {
    let _ = AppSync_Resolver_Retrying.makeSubscriptionResolver(
      ~name="on" ++ field->String.capitalize,
      ~api,
      ~field="on" ++ field,
      ~dataSourceName,
      ~opts,
    )
  })
