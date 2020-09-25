module Make =
       (Spec: CommandGenerator.Spec)
       : (CommandGenerator.T with module Spec = Spec) => {
  module Spec = Spec;
  type commandHandler = Message.commandHandler(Spec.Id.t, Spec.command);

  type t;

  let make:
    (
      ~name: string,
      ~commandHandler: commandHandler,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    Component.t(t,CommandGenerator.outputs) =
    (~name as _, ~commandHandler as _, ~opts as _=?, _unit) => {
      ()->Obj.magic;
    };
};
