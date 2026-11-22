/** @pulumi/aws/appsync/ApiKey
  see: https://www.pulumi.com/registry/packages/aws/api-docs/appsync/apikey

  A key for a `GraphQLApi` whose authorization is `API_KEY`. A key lives at most a
  year: `expires` is an RFC 3339 time, rounded down to the hour by AppSync, and a
  deploy that sets a later one renews the key in place, with the same value.
*/
type t = {
  id: Pulumi.Output.t<string>,
  /** The key's value: what a caller sends as `x-api-key`. */
  key: Pulumi.Output.t<string>,
}
type apiKey = t

type args = {
  apiId: Pulumi.Input.t<string>,
  description?: Pulumi.Input.t<string>,
  expires?: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("appsync") @new
external make: (
  ~name: string,
  ~args: args=?,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) => apiKey = "ApiKey"
