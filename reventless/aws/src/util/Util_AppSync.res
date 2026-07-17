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

/** Variant for aws-native.appsync.Resolver (different field names: resolverArn
    vs arn, typeName vs type_, fieldName vs field). Emits the same
    ReventlessInfra.Adapter.resource shape as the classic variant. */
let toResourceNative: PulumiAws.AwsNative.AppSync.Resolver.t => ReventlessInfra.Adapter.resource = ({
  id,
  resolverArn,
  typeName,
  fieldName,
}) =>
  ReventlessInfra.Adapter.make(
    ~name=id,
    ~id,
    ~urn=resolverArn,
    ~service=id->Pulumi.Output.apply(_ => AWS.AppSync.service),
    ~resourceInfo=(typeName, fieldName)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((t, f)) => ReventlessInfra.Adapter.ApiResolver({typeName: t, fieldName: f})),
    ~resourceType="aws-native:appsync:Resolver"->Pulumi.Output.make,
  )
