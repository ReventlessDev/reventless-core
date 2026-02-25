type runtimeBucket = {
  id: string,
  name: string,
  arn: string,
}

let toRuntimeBucket = ({id, name, urn}: Reventless.Adapter.resolvedResource) => {
  id,
  name,
  arn: urn,
}
