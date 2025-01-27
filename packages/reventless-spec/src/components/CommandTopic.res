type publish<'id, 'command> = Message.command'<'id, 'command> => Js.Promise.t<unit>
type publishJsons = array<Message.commandJson> => Js.Promise.t<unit>

type outputs = {
  resources: array<Adapter.resource>,
  publishJsons: Pulumi.Output.t<publishJsons>,
}

type topicItem<'command> = {
  command: 'command,
  reference: string,
}

type commandsHandler<'command> = array<topicItem<'command>> => Js.Promise.t<
  array<Belt.Result.t<string, string>>,
>

module type Spec = {
  module Id: Id.T

  @decco
  type command
}
