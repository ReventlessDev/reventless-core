module Make =
       (Spec: CommandGenerator.Spec)
       : (CommandGenerator.T with module Spec = Spec) => {
  module Spec = Spec;
  type commandHandler = Message.commandHandler(Spec.Id.t, Spec.command);

  type t;

  let make =
      (~name as _, ~commandHandler as _, ~opts as _=?, ~resources as _, _) => {
    ()->Obj.magic;
  };
};
