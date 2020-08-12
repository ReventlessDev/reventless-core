module Make =
       (Spec: CommandGenerator.Spec)
       : (CommandGenerator.T with module Spec = Spec) => {
  module Spec = Spec;
  type commandHandler = Message.commandHandler(Spec.Id.t, Spec.command);

  type t = unit;

  let make:
    (
      ~commandHandler: commandHandler,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    t =
    (~commandHandler, ~opts=?, _) => {
      let _ = (commandHandler, opts);
      ();
    };
};
