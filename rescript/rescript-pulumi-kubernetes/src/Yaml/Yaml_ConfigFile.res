/** @pulumi/kubernetes yaml ConfigFile — register the resources in a single
  vendored YAML manifest (file path or URL).
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/yaml/configfile/

  A `ConfigFile` is a ComponentResource; it takes ComponentResource options.
*/
type t = {urn: Pulumi.Output.t<string>}

type args = {
  /** Path or URL to a `.yaml`/`.yml` manifest. */
  file: string,
  /** Prefix applied to every child resource's Pulumi name. */
  resourcePrefix?: string,
}

@module("@pulumi/kubernetes") @scope("yaml") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.ComponentResource.options=?, unit) => t =
  "ConfigFile"
