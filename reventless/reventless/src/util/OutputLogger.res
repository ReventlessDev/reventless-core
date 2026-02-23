let logOutput: (
  ~loc: string=?,
  ~map: 'a => 'b=?,
  ~stringify: bool=?,
  ~level: Logger.Level.t=?,
  string,
  Pulumi.Output.t<'a>,
) => unit = (~loc=?, ~map=?, ~stringify=?, ~level=?, desc, output) =>
  if output->Pulumi.Output.isOutput {
    output
    ->Pulumi.Output.apply(item => Logger.log(~loc?, ~map?, ~stringify?, ~level?, desc, item))
    ->ignore
  } else {
    let itemType = (output->typeof :> string)
    Logger.log(
      ~loc?,
      ~map?,
      ~stringify?,
      ~level=Logger.Level.Error,
      desc ++ (" ~}> was expected to be a Pulumi.Output.t, but is " ++ (itemType ++ "!")),
      output->Pulumi.Output.unwrap,
    )
  }
