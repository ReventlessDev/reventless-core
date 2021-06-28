type action('id, 'command) =
  | Publish('id, 'command)
  | PublishDelayed('id, 'command, int)
  | PublishAsync(Js.Promise.t(array(('id, 'command))))
  | Call('command => Js.Promise.t(unit), 'command);

module type T = {
  module Source: AggregateSpec.T;

  type targetId;
  type targetCommand;

  let map:
    (. Source.Id.t, Source.event, ReventlessSpec.QueryEngine.t) =>
    array(action(targetId, targetCommand));
};

module type Mappings = {
  module Target: AggregateSpec.T;

  let mappings:
    array(
      module T with
        type targetId = Target.Id.t and type targetCommand = Target.command,
    );
};
