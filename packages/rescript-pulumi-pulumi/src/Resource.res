/** @pulumi/pulumi/Resource
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/classes/Resource.html
*/
type rec t = {
  @as("__name") name: option<string>,
  @as("__pulumiType") pulumiType: string,
  urn: Output.t<string>,
  @as("__parentResource") parent: option<t>,
  @as("__childResources") children: Set.t<t>,
}

external makeFromJs: 'a => t = "%identity"
