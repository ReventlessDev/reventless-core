type resource = {
  .
  "name": Pulumi.Output.t(string),
  "id": Pulumi.Output.t(string),
  "urn": Pulumi.Output.t(string),
  "info": Pulumi.Output.t(string),
  "service": string,
};

[@bs.obj]
external resource:
  (
    ~service: string,
    ~name: Pulumi.Output.t(string),
    ~id: Pulumi.Output.t(string),
    ~urn: Pulumi.Output.t(string),
    ~info: Pulumi.Output.t(string)
  ) =>
  resource =
  "";

type dict = Js.Dict.t(resource);