/** @pulumi/kubernetes apps/v1 StatefulSet
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/apps/v1/statefulset/
*/
type rollingUpdateStatefulSetStrategy = {partition?: int}
type statefulSetUpdateStrategy = {
  @as("type") type_?: string,
  rollingUpdate?: rollingUpdateStatefulSetStrategy,
}

/** A PVC embedded in `volumeClaimTemplates` — metadata plus the same spec type
  as a standalone PersistentVolumeClaim. */
type persistentVolumeClaim = {
  metadata?: Meta.objectMeta,
  spec: Core_PersistentVolumeClaim.persistentVolumeClaimSpec,
}

type statefulSetSpec = {
  selector: Meta.labelSelector,
  template: Core_Pod.podTemplateSpec,
  serviceName: string,
  replicas?: int,
  podManagementPolicy?: string,
  updateStrategy?: statefulSetUpdateStrategy,
  volumeClaimTemplates?: array<persistentVolumeClaim>,
  revisionHistoryLimit?: int,
  minReadySeconds?: int,
}

type t = {
  id: Pulumi.Output.t<string>,
  apiVersion: Pulumi.Output.t<string>,
  kind: Pulumi.Output.t<string>,
  metadata: Pulumi.Output.t<Meta.objectMeta>,
  spec: Pulumi.Output.t<statefulSetSpec>,
}

type args = {
  metadata?: Pulumi.Input.t<Meta.objectMeta>,
  spec?: Pulumi.Input.t<statefulSetSpec>,
}

@module("@pulumi/kubernetes") @scope(("apps", "v1")) @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t =
  "StatefulSet"
