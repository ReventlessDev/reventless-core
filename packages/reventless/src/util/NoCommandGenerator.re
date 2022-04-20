module Make =
       (Spec: CommandGenerator.Spec)
       : (CommandGenerator.T with module Spec = Spec) => {
  module Spec = Spec;
  type publish = Message.commandHandler(Spec.Id.t, Spec.command);

  type t;

  let make:
    (
      ~name: string,
      ~publish: publish,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    Component.t(t, CommandGenerator.outputs) =
    (~name as _, ~publish as _, ~opts as _=?, _unit) => {
      ()->Obj.magic;
    };
};
