let toResource = (resolver: PulumiAws.AppSync.Resolver.t) =>
  Reventless.Adapter.resource(
    ~service="AppSync",
    ~name=resolver##id,
    ~id=resolver##id,
    ~urn=resolver##arn,
    ~info=
      (resolver##_type, resolver##field)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((type_, field)) => type_ ++ "." ++ field),
  );