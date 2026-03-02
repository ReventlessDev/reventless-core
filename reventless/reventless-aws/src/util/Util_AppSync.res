let toResource: Types.AppSync.resolver => ReventlessInfra.Adapter.resource = ({
  id,
  arn,
  type_,
  field,
}) => {
  service: id->Pulumi.Output.apply(_ => AWS.AppSync.service),
  name: id,
  id,
  urn: arn,
  info: (type_, field)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((type_, field)) => type_ ++ ("." ++ field)),
}
