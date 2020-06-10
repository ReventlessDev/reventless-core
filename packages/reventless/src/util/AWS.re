let updateRegion = () => {
  Pulumi.(
    AwsSdk.Config.(
      Config.make(Some("aws"))->Config.require("region")
      |> UpdateParams.make(~region=_)
      |> update(~param=_)
    )
  );
};
