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

type args = {
  /** The AppSync Events API ID this namespace belongs to. Required. */
  apiId: Pulumi.Input.t<string>,
  /** Namespace name. Defaults to Pulumi resource name. Use `"default"`. */
  name?: Pulumi.Input.t<string>,
  /** Auth modes for publish operations. Defaults to API-level auth. */
  publishAuthModes?: Pulumi.Input.t<array<Pulumi.Input.t<authMode>>>,
  /** Auth modes for subscribe operations. Defaults to API-level auth. */
  subscribeAuthModes?: Pulumi.Input.t<array<Pulumi.Input.t<authMode>>>,
}

@module("@pulumi/aws-native") @scope("appsync") @new
external make: (
  ~name: string,
  ~args: args,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) => t = "ChannelNamespace"
