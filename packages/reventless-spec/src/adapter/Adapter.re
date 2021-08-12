type resource = {
  .
  "name": Pulumi.Output.t(string),
  "id": Pulumi.Output.t(string),
  "urn": Pulumi.Output.t(string),
  "info": Pulumi.Output.t(string),
  "service": string,
};

type resources = Js.Dict.t(resource);
