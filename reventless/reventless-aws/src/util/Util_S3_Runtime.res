type runtimeBucket = {
  id: string,
  name: string,
  arn: string,
}

let toRuntimeBucket = ({id, name, urn}: Reventless.Adapter.unwrappedResource) => {
  id,
  name,
  arn: urn,
}
