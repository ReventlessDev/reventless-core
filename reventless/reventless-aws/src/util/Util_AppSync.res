let toResource: Types.AppSync.resolver => ReventlessInfra.Adapter.resource = ({
  id,
  arn,
  type_,
  field,
}) =>
  ReventlessInfra.Adapter.make(
    ~name=id,
    ~id,
    ~urn=arn,
    ~service=id->Pulumi.Output.apply(_ => AWS.AppSync.service),
    ~resourceInfo=(type_, field)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((type_, field)) => ReventlessInfra.Adapter.ApiResolver({typeName: type_, fieldName: field})),
    ~resourceType="aws:appsync:Resolver"->Pulumi.Output.make,
  )
