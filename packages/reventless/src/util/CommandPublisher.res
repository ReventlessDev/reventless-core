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

let commandsToJsons = (buffer, size, service, user, command_encode) => {
  let commandsToSend = buffer->Js.Array2.removeCountInPlace(~pos=0, ~count=size)
  Js.log4(
    "commandsToJsons: commandsToSend:",
    commandsToSend->Belt.Array.size,
    "rest:",
    buffer->Belt.Array.size,
  )
  commandsToSend->Belt.Array.map(((id, command)) => {
    let commandJson = command->command_encode
    {
      ReventlessSpec.Message.id,
      meta: Reventless.Message.generateMeta(~service, ~user, ()),
      commandJson,
      delay: None,
    }
  })
}

module Make = (Spec: Spec, Config: Config) => {
  let buffer = []
  let running = ref(None)

  let finishRunning = async () =>
    switch running.contents {
    | None => ()
    | Some(promise) =>
      try await promise catch {
      | Js.Exn.Error(e) => Js.log2("CommandPublisher: Error: Couldn't publish commands", e)
      }
      running := None
    }

  let rec send = async flush => {
    await finishRunning()
    switch Config.mode {
    | SendChunks(chunkSize) =>
      let size = Js.Math.min_int(chunkSize, buffer->Belt.Array.size)
      Js.log4("send: buffer:", buffer->Belt.Array.size, "size:", size)
      switch await Config.publishCommands(.
        Spec.name,
        commandsToJsons(buffer, size, Spec.name, Config.user, Spec.command_encode),
      ) {
      | () =>
        Js.log3("CommandPublisher: published commands:", size, flush ? "flush" : "")
        if buffer->Belt.Array.size >= chunkSize || flush {
          await send(flush)
        } else {
          running := None
        }
      | exception Js.Exn.Error(e) =>
        Js.log2("CommandPublisher: Error: Couldn't publish commands", e)
      }
    | SendAllInOneChunk =>
      let size = buffer->Belt.Array.size
      switch await Config.publishCommands(.
        Spec.name,
        commandsToJsons(buffer, size, Spec.name, Config.user, Spec.command_encode),
      ) {
      | () => Js.log3("CommandPublisher: published commands:", size, flush ? "flush" : "")
      | exception Js.Exn.Error(e) =>
        Js.log2("CommandPublisher: Error: Couldn't publish commands", e)
      }
      running := None
    }
  }

  let publish = (id: string, command: Spec.command) => {
    let _ = buffer->Js.Array2.push((id, command))
    switch (running.contents, Config.mode) {
    | (None, SendChunks(chunkSize)) if buffer->Belt.Array.size >= chunkSize =>
      let _ = send(false)
    | _ => ()
    }
  }

  let flush = async () => {
    await finishRunning()
    await send(true)
  }

  let clear = () => {
    let _ = buffer->Js.Array2.removeFromInPlace(~pos=0)
  }
}
