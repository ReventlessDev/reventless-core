type resolvedBucket = {
  id: string,
  name: string,
  arn: string,
}

let toResolvedBucket = ({id, name, urn}: ReventlessCore.Adapter.resolvedResource) => {
  id,
  name,
  arn: urn,
}
