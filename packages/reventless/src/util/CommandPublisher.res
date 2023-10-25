module type Spec = {
  @decco
  let name: string
  @decco
  type command
}

type mode = SendChunks(int) | SendAllInOneChunk

module type Config = {
  let user: string
  let publishCommands: Task.publishCommands
  let mode: mode
}

module Make = (Spec: Spec, Config: Config) => {
  let buffer = []
  let promises = []

  let send = () => {
    let sentChunksCount = promises->Belt.Array.size
    switch Config.mode {
    | SendChunks(_) => Js.log(`sending chunk ${sentChunksCount->Belt.Int.toString}:`)
    | SendAllInOneChunk => ()
    }
    let commandJsons = buffer->Belt.Array.map(((id, command)) => {
      let commandJson = command->Spec.command_encode
      {
        ReventlessSpec.Message.id,
        meta: Reventless.Message.generateMeta(~service=Spec.name, ~user=Config.user, ()),
        commandJson,
        delay: None,
      }
    })
    promises->Js.Array2.push(Config.publishCommands(. Spec.name, commandJsons))->ignore
    buffer->Js.Array2.removeFromInPlace(~pos=0)->ignore
  }

  let publish = (id: string, command: Spec.command) => {
    buffer->Js.Array2.push((id, command))->ignore
    switch Config.mode {
    | SendChunks(chunkSize) =>
      if buffer->Belt.Array.size >= chunkSize {
        send()
      }
    | SendAllInOneChunk => ()
    }
  }

  let flush = async () => {
    send()
    let _results = await promises->Js.Array2.removeFromInPlace(~pos=0)->Util.Promise.allSettled
  }

  let clear = () => buffer->Js.Array2.removeFromInPlace(~pos=0)->ignore
}
