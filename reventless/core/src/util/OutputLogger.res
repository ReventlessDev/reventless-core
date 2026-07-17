let logOutput: (string, Pulumi.Output.t<'a>) => unit = (desc, output) =>
  if output->Pulumi.Output.isOutput {
    output
    ->Pulumi.Output.apply(item => Console.log2(desc, item))
    ->ignore
  } else {
    let itemType = (output->typeof :> string)
    Console.error(desc ++ " ~}> was expected to be a Pulumi.Output.t, but is " ++ itemType ++ "!")
  }
