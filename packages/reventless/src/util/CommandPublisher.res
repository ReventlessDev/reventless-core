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

let commandsToJsons = (buffer, size, service, user, command_encode) =>
  buffer
  ->Js.Array2.removeCountInPlace(~pos=0, ~count=size)
  ->Belt.Array.map(((id, command)) => {
    let commandJson = command->command_encode
    {
      ReventlessSpec.Message.id,
      meta: Reventless.Message.generateMeta(~service, ~user, ()),
      commandJson,
      delay: None,
    }
  })

module Make = (Spec: Spec, Config: Config) => {
  let buffer = []
  let running = ref(None)

  let rec send = async flush => {
    await (
      switch running.contents {
      | None =>
        let promise = Js.Promise.resolve()
        running := Some(promise)
        promise
      | Some(promise) => promise
      }
    )

    switch Config.mode {
    | SendChunks(chunkSize) =>
      if buffer->Belt.Array.size >= chunkSize || flush {
        let size = Js.Math.min_int(chunkSize, buffer->Belt.Array.size)
        switch await Config.publishCommands(.
          Spec.name,
          commandsToJsons(buffer, size, Spec.name, Config.user, Spec.command_encode),
        ) {
        | () =>
          Js.log2("CommandPublisher: published commands:", size)
          await send(flush)
        | exception Js.Exn.Error(e) =>
          Js.log2("CommandPublisher: Error: Couldn't publish commands", e)
        }
      } else {
        running := None
      }
    | SendAllInOneChunk =>
      let size = buffer->Belt.Array.size
      switch await Config.publishCommands(.
        Spec.name,
        commandsToJsons(buffer, size, Spec.name, Config.user, Spec.command_encode),
      ) {
      | () => Js.log2("CommandPublisher: published commands:", size)
      | exception Js.Exn.Error(e) =>
        Js.log2("CommandPublisher: Error: Couldn't publish commands", e)
      }
      running := None
    }
  }

  let publish = (id: string, command: Spec.command) => {
    let _ = buffer->Js.Array2.push((id, command))
    let _ = send(false)
  }

  let flush = async () => {
    await (
      switch running.contents {
      | None =>
        let promise = Js.Promise.resolve()
        running := Some(promise)
        promise
      | Some(promise) => promise
      }
    )

    await send(true)
  }

  let clear = () => {
    let _ = buffer->Js.Array2.removeFromInPlace(~pos=0)
  }
}
