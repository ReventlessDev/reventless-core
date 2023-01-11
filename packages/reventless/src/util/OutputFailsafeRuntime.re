let get: Pulumi.Output.t(string) => string =
  output =>
    if (output->Js.typeof == "string") {
      output->Pulumi.Output.unwrap;
    } else {
      output->Pulumi.Output.get;
    };
