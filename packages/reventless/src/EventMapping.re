type action('id, 'command) =
  | Publish('id, 'command)
  | PublishDelayed('id, 'command, int)
  | PublishAsync(Js.Promise.t(array(('id, 'command))))
  | Call(Message.handler('command), 'command);

module type T = {
  module Source: Aggregate.Spec;

  type targetId;
  type targetCommand;

  let map:
    (. Source.Id.t, Source.event, ReventlessSpec.QueryEngine.t) =>
    array(action(targetId, targetCommand));
};

module type Mappings = {
  module Target: Aggregate.Spec;

  let mappings:
    array(
      module T with
        type targetId = Target.Id.t and type targetCommand = Target.command,
    );
};
