type encode<'a> = 'a => JSON.t
type decode<'a> = JSON.t => 'a

module type GenericSource = {
  let name: string
  type t
  let decode': decode<Message.event'<string, t>> // why decode' ?
}

module type GenericTarget = {
  let name: string
  type t
  let decode: decode<t>
  let encode: encode<t>
}

module type EventSource = {
  module Id: ReventlessSpec.Id.T
  let name: string
  @schema
  type event
}

module type CommandTarget = {
  let name: string
  @schema
  type command
}

// TODO: en/decode command'
module MakeGenericTargetFromCommandTarget = (CommandTarget: CommandTarget): GenericTarget => {
  let name = CommandTarget.name
  type t = CommandTarget.command
  let decode = json => json->Message.decode(CommandTarget.commandSchema)
  let encode = cmd => cmd->Message.encode(CommandTarget.commandSchema)
}
