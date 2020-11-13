type forwardCommand = {
  extensionPointName: string,
  id: string,
  commandJson: Js.Json.t,
};

/* these actions are needed for Impl */
type incomingCommandAction('aggregateCommand, 'extensionPointCommand, 'msg) =
  | PublishAggregateCommand(string, 'aggregateCommand)
  | PublishExtensionPointCommand(string, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | Call('msg => Js.Promise.t(unit), 'msg);

type outgoingCommandAction('extensionPointCommand, 'msg) =
  | PublishExtensionPointCommand(string, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | Call('msg => Js.Promise.t(unit), 'msg);

module NoAggregate = {
  let name = "NoAggregate";

  module Id = {
    [@decco]
    type t = string;
    type input = string;
    external make: t => t = "%identity";
    external makeFromString: string => t = "%identity";
    external toString: t => t = "%identity";
    let cmp = String.compare;
  };

  [@decco]
  type command = unit;

  [@decco]
  type event = unit;

  [@decco]
  type error = unit;
};
