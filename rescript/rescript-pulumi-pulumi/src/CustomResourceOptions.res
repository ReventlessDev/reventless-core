/** @pulumi/pulumi/CustomResourceOptions
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/interfaces/CustomResourceOptions.html
*/
type t = {
  deleteBeforeReplace?: bool,
  dependsOn?: Input.t<array<Resource.t>>,
  id?: string,
  parent?: Resource.t,
  protect?: bool,
  provider?: ProviderResource.t,
}
