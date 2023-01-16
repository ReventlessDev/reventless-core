module Make =
       (Spec: CommandGenerator.Spec)
       : (CommandGenerator.T with module Spec = Spec) => {
  module Spec = Spec;
  type publish = Message.commandHandler(Spec.Id.t, Spec.command);

  [@obj]
  external makeOutputs:
    (~resources: array(ReventlessSpec.Adapter.resource)) =>
    CommandGenerator.outputs;

  external outputsToComponent:
    CommandGenerator.outputs => CommandGenerator.component =
    "%identity";

  let make = (~name as _, ~publish as _, ~opts as _=?, _unit) => {
    makeOutputs(~resources=[||])->outputsToComponent;
  };
};
