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
  /** Drop the resource from state without deleting it in the cloud —
      on a replacement the old physical resource is left behind rather
      than destroyed. */
  retainOnDelete?: bool,
  /** Aliases allow renaming or retyping a resource without a
      delete-then-create cycle. Each entry describes the OLD identity
      so Pulumi can match the existing state entry to the new declaration.
      See Alias.make for construction. */
  aliases?: array<Alias.t>,
}
