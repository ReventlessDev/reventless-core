let service = "AppSync"

let toResource: PulumiAws.AppSync.Resolver.t => ReventlessSpec.Adapter.resource = ({
  id,
  arn,
  type_,
  field,
}) => {
  service: id->Pulumi.Output.apply(_ => service),
  name: id,
  id,
  urn: arn,
  info: (type_, field)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((type_, field)) => type_ ++ ("." ++ field)),
}
