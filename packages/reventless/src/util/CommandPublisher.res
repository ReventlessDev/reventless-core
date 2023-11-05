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

  let commandsToJsons = size => {
    let commandsToSend = buffer->Js.Array2.removeCountInPlace(~pos=0, ~count=size)
    Js.log4(
      "commandsToJsons: commandsToSend:",
      commandsToSend->Belt.Array.size,
      "rest:",
      buffer->Belt.Array.size,
    )
    commandsToSend->Belt.Array.map(((id, command)) => {
      let commandJson = command->Spec.command_encode
      {
        ReventlessSpec.Message.id,
        meta: Reventless.Message.generateMeta(~service=Spec.name, ~user=Config.user, ()),
        commandJson,
        delay: None,
      }
    })
  }

  let rec send = async flush => {
    await finishRunning()
    switch Config.mode {
    | SendChunks(chunkSize) =>
      let size = Js.Math.min_int(chunkSize, buffer->Belt.Array.size)
      if size >= chunkSize || (size > 0 && flush) {
        Js.log4("send: buffer:", buffer->Belt.Array.size, "size:", size)
        let promise = Config.publishCommands(. Spec.name, commandsToJsons(size))
        running := Some(promise)
        switch await promise {
        | () =>
          Js.log3("CommandPublisher: finished SendChunk:", size, flush ? "flush" : "")
          if buffer->Belt.Array.size >= chunkSize || (size > 0 && flush) {
            await send(flush)
          }
        | exception Js.Exn.Error(e) =>
          Js.log2("CommandPublisher: Error: Couldn't publish commands", e)
        }
        running := None
      }
    | SendAllInOneChunk =>
      let size = buffer->Belt.Array.size
      if size > 0 {
        let promise = Config.publishCommands(. Spec.name, commandsToJsons(size))
        running := Some(promise)
        switch await promise {
        | () => Js.log3("CommandPublisher: finished SendAllInOneChunk:", size, flush ? "flush" : "")
        | exception Js.Exn.Error(e) =>
          Js.log2("CommandPublisher: Error: Couldn't publish commands", e)
        }
        running := None
      }
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
    Js.log("CommandPublisher.flush")
    await finishRunning()
    await send(true)
  }

  let clear = () => {
    Js.log("CommandPublisher.clear")
    let _ = buffer->Js.Array2.removeFromInPlace(~pos=0)
  }
}
