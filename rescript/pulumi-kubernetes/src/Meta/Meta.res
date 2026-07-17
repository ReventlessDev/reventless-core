/** @pulumi/kubernetes meta/v1 — ObjectMeta and selector types shared by every kind.
  see: https://www.pulumi.com/registry/packages/kubernetes/api-docs/meta/v1/
*/

/** ObjectMeta — the metadata block carried by every Kubernetes object. Only the
  fields consumers routinely set are bound; the long tail (ownerReferences,
  finalizers, managedFields, …) is intentionally omitted. */
type objectMeta = {
  name?: string,
  namespace?: string,
  generateName?: string,
  labels?: dict<string>,
  annotations?: dict<string>,
}

/** Convenience constructor so callers can write
  `Meta.objectMeta(~name="app", ~labels=..., ())` instead of a bare record. */
let objectMeta = (
  ~name=?,
  ~namespace=?,
  ~generateName=?,
  ~labels=?,
  ~annotations=?,
  (),
): objectMeta => {
  ?name,
  ?namespace,
  ?generateName,
  ?labels,
  ?annotations,
}

type labelSelectorRequirement = {
  key: string,
  operator: string,
  values?: array<string>,
}

type labelSelector = {
  matchLabels?: dict<string>,
  matchExpressions?: array<labelSelectorRequirement>,
}
