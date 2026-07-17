/** @pulumi/kubernetes core/v1 PersistentVolumeClaim
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/core/v1/persistentvolumeclaim/
*/
type persistentVolumeClaimSpec = {
  accessModes?: array<string>,
  resources?: Core_Pod.resourceRequirements,
  storageClassName?: string,
  volumeMode?: string,
  volumeName?: string,
  selector?: Meta.labelSelector,
}

type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
  spec: Pulumi.Output.t<persistentVolumeClaimSpec>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  spec?: Pulumi.Input.t<persistentVolumeClaimSpec>,
}

@module("@pulumi/kubernetes") @scope(("core", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "PersistentVolumeClaim"
