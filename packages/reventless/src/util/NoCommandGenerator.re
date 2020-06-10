module Make =
       (Service: Message.Service)

         : (
           CommandGenerator.T with
             type id = Service.id and type command = Service.command
       ) => {
  type id = Service.id;
  type command = Service.command;

  type commandHandler = Message.commandHandler(id, command);

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
