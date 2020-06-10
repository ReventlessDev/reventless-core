let get: Pulumi.Output.t(string) => string =
  output =>
    if (output->Js.typeof == "string") {
      output->Obj.magic;
    } else {
      output->Pulumi.Output.get;
    };
