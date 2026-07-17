/** @pulumi/pulumi/InvokeOptions
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/interfaces/InvokeOptions.html
*/
type t = {
  parent?: Resource.t,
  provider?: ProviderResource.t,
  version?: string,
  async?: bool,
}
