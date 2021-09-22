/** see ReventlessSpec.AggregateSpec.T */
module type Source = {
  let name: string;
  module Id: Id.T;
  [@decco]
  type event;
};

/** see ReventlessSpec.AggregateSpec.T */
module type Target = {
  let name: string;
  module Id: Id.T;
  [@decco]
  type command;
};

type action('id, 'command) =
  | Publish('id, 'command)
  | PublishDelayed('id, 'command, int)
  | PublishAsync(Js.Promise.t(array(('id, 'command))))
  | SetCounterTarget(AtomicCounter.counterTarget)
  | Count(AtomicCounter.countItem);

module type T = {
  module Source: Source;
  module Target: Target;
  let map:
    (. Source.Id.t, Source.event, QueryEngine.t) =>
    array(action(Target.Id.t, Target.command));
};
