/** @pulumi/kubernetes yaml ConfigGroup — register the resources across several
  manifests (file paths / URLs / globs, or inline YAML strings).
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/yaml/configgroup/

  A `ConfigGroup` is a ComponentResource; it takes ComponentResource options.
*/
type t = {urn: Pulumi.Output.t<string>}

type args = {
  /** File paths, URLs or globs. (The JS API also accepts a bare string; pass a
    single-element array here.) */
  files?: array<string>,
  /** Inline YAML documents. */
  yaml?: array<string>,
  resourcePrefix?: string,
}

@module("@pulumi/kubernetes") @scope("yaml") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.ComponentResource.options=?, unit) => t =
  "ConfigGroup"
