let updateRegion = () => {
  AwsSdk.Config.(
    Pulumi.Config.make(Some("aws"))->Pulumi.Config.require("region")
    |> UpdateParams.make(~region=_)
    |> update(~param=_)
  );
};

let invalidNameChars = [%re "/[^.\-_a-zA-Z0-9]/g"];

let validateName = Js.String2.replaceByRe(_, invalidNameChars, "_");
