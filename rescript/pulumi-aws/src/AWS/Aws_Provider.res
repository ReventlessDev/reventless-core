/** @pulumi/aws/Provider
  see: https://www.pulumi.com/registry/packages/aws/api-docs/provider
*/
type args = {region: Pulumi.Input.t<string>}

type t = Pulumi.ProviderResource.t

@module("@pulumi/aws") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Provider"
