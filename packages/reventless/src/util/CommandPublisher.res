module type Spec = {
  @schema
  let name: string
  @schema
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
  let flush = ref(false)
  let chunkCount = ref(0)

  let finishRunning = async () =>
    switch running.contents {
    | None => ()
    | Some(promise) =>
      try await promise catch {
      | Js.Exn.Error(e) => Logger.error(~loc=__LOC__, "Couldn't publish commands", e)
      }
    }

  let toJsons = commandsToSend => {
    Js.log4("toJsons: commandsToSend:", commandsToSend->Array.length, "rest:", buffer->Array.length)
    commandsToSend->Array.map(((id, command)) => {
      let commandJson = command->Message.encode(Spec.commandSchema)
      {
        ReventlessSpec.Message.id,
        meta: Reventless.Message.generateMeta(~service=Spec.name, ~user=Config.user),
        commandJson,
        delay: None,
      }
    })
  }

  let rec send = async () => {
    await finishRunning()
    switch Config.mode {
    | SendChunks(chunkSize) =>
      let size = Js.Math.min_int(chunkSize, buffer->Array.length)
      if size >= chunkSize || (size > 0 && flush.contents) {
        chunkCount := chunkCount.contents + 1
        let sizeStr = size->Int.toString
        let bufferSizeStr = buffer->Array.length->Int.toString
        let chunkCountStr = chunkCount.contents->Js.Int.toString
        Logger.debug(
          ~loc=__LOC__,
          "send",
          `bufferSize: ${bufferSizeStr}, chunk: ${chunkCountStr}, size: ${sizeStr}`,
        )
        let commandsToSend = buffer->Js.Array2.removeCountInPlace(~pos=0, ~count=size)
        let promise = Config.publishCommands(Spec.name, commandsToSend->toJsons)
        running := Some(promise)
        switch await promise {
        | () => Logger.debug(~loc=__LOC__, "send", `finished chunk ${chunkCountStr}: ${sizeStr}`)
        | exception Js.Exn.Error(e) =>
          let errorMessage = e->Js.Exn.message->Option.getOr("unknown Error")
          Js.log(
            `CommandPublisher.send: Error: Couldn't publish chunk ${chunkCountStr}: ${errorMessage}`,
          )
          let timeout = Js.Math.random_int(3000, 7000)
          await Util.Promise.finishTimeout(timeout)
          Js.log(`Retry sending after ${timeout->Js.Int.toString} ms ...`)
          chunkCount := chunkCount.contents - 1
          let _ = buffer->Js.Array2.unshiftMany(commandsToSend)
        }
        await send()
      } else {
        running := None
      }
    | SendAllInOneChunk =>
      let size = buffer->Array.length
      if size > 0 {
        let commandsToSend = buffer->Js.Array2.removeCountInPlace(~pos=0, ~count=size)
        let promise = Config.publishCommands(Spec.name, commandsToSend->toJsons)
        running := Some(promise)
        switch await promise {
        | () => Js.log2("CommandPublisher.send: finished SendAllInOneChunk:", size)
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
    | (None, SendChunks(chunkSize)) if buffer->Array.length >= chunkSize =>
      running := Some(Js.Promise.resolve())
      let _ = send()
    | _ => ()
    }
  }

  let clear = () => {
    Js.log("CommandPublisher.clear")
    let _ = buffer->Js.Array2.removeFromInPlace(~pos=0)
    flush := false
  }

  let flush = async () => {
    Js.log("CommandPublisher.flush")
    flush := true
    switch running.contents {
    | None => await send()
    | _ =>
      while running.contents->Option.isNone {
        await finishRunning()
      }
    }
  }
}
