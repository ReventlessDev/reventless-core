module Make =
       (Spec: CommandGenerator.Spec)
       : (CommandGenerator.T with module Spec = Spec) => {
  module Spec = Spec;
  type commandHandler = Message.commandHandler(Spec.Id.t, Spec.command);

  type t = unit;

  let make:
    (
      ~name: string,
      ~commandHandler: commandHandler,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    t =
    (~name, ~commandHandler, ~opts=?, _) => {
      let _ = (name, commandHandler, opts);
      ();
    };
};
