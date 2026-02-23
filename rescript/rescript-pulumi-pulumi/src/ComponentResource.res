/** @pulumi/pulumi/ComponentResourceOptions
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/interfaces/ComponentResourceOptions.html
*/
type options = {
  dependsOn?: Input.t<array<Resource.t>>,
  id?: string,
  parent?: Resource.t,
  protect?: bool,
  provider?: ProviderResource.t,
  providers?: dict<ProviderResource.t>,
}
