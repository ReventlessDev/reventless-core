let apply:
  (Pulumi.Output.t(string), string => string) => Pulumi.Output.t(string) =
  (output, f) =>
    (
      if (output->Js.typeof == "string") {
        output->Pulumi.Output.unwrap->Pulumi.Output.make;
      } else {
        output;
      }
    )
    ->Pulumi.Output.apply(f);

let flatMap:
  (Pulumi.Output.t(string), string => Pulumi.Output.t(string)) =>
  Pulumi.Output.t(string) =
  (output, f) =>
    (
      if (output->Js.typeof == "string") {
        output->Pulumi.Output.unwrap->Pulumi.Output.make;
      } else {
        output;
      }
    )
    ->Pulumi.Output.flatMap(f);
