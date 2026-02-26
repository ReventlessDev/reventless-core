type runtimeBucket = {
  id: string,
  name: string,
  arn: string,
}

let toRuntimeBucket = ({id, name, urn}: ReventlessCore.Adapter.resolvedResource) => {
  id,
  name,
  arn: urn,
}
