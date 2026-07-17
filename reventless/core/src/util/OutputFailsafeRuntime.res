let get: Pulumi.Output.t<string> => string = output =>
  if output->typeof == #string {
    output->Pulumi.Output.unwrap
  } else {
    output->Pulumi.Output.get
  }
