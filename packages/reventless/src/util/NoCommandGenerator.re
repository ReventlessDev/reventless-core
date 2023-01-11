module Make =
       (Spec: CommandGenerator.Spec)
       : (CommandGenerator.T with module Spec = Spec) => {
  module Spec = Spec;
  type publish = Message.commandHandler(Spec.Id.t, Spec.command);

  let make = (~name as _, ~publish as _, ~opts as _=?, _unit) => {
    ()->Obj.magic;
  };
};
