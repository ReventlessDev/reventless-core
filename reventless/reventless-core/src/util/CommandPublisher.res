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
      | JsExn(e) =>
        let errMsg = e->JsExn.message->Option.getOr("unknown")
        EffectLogger.logError(~comp="CommandPublisher", `Couldn't publish commands: ${errMsg}`)->Effect.runSync
      }
    }

  let toJsons = commandsToSend => {
    EffectLogger.logDebug(
      ~comp="CommandPublisher",
      `toJsons: commandsToSend: ${commandsToSend->Array.length->Int.toString} rest: ${buffer
        ->Array.length
        ->Int.toString}`,
    )->Effect.runSync
    commandsToSend->Array.map(((id, command)) => {
      let commandJson = command->Message.encode(Spec.commandSchema)
      {
        Reventless.Message.id,
        meta: Message.generateMeta(~service=Spec.name, ~user=Config.user),
        commandJson,
      }
    })
  }

  // Sends buffered commands. The underlying publishCommands (SQS) already retries
  // transient failures — no retry at this layer.
  let rec send = async () => {
    await finishRunning()
    switch Config.mode {
    | SendChunks(chunkSize) =>
      let size = Math.Int.min(chunkSize, buffer->Array.length)
      if size >= chunkSize || (size > 0 && flush.contents) {
        chunkCount := chunkCount.contents + 1
        let sizeStr = size->Int.toString
        let bufferSizeStr = buffer->Array.length->Int.toString
        let chunkCountStr = chunkCount.contents->Int.toString
        EffectLogger.logDebug(
          ~comp="CommandPublisher",
          `send: bufferSize: ${bufferSizeStr}, chunk: ${chunkCountStr}, size: ${sizeStr}`,
        )->Effect.runSync
        let commandsToSend = buffer->Array.toSpliced(~start=0, ~remove=size, ~insert=[])
        let promise = Config.publishCommands(Spec.name, commandsToSend->toJsons)
        running := Some(promise)
        switch await promise {
        | () => EffectLogger.logDebug(~comp="CommandPublisher", `send: finished chunk ${chunkCountStr}: ${sizeStr}`)->Effect.runSync
        | exception JsExn(e) =>
          let errorMessage = e->JsExn.message->Option.getOr("unknown Error")
          EffectLogger.logError(
            ~comp="CommandPublisher",
            `send error: couldn't publish chunk ${chunkCountStr} (${sizeStr} commands): ${errorMessage}`,
          )->Effect.runSync
        }
        await send()
      } else {
        running := None
      }
    | SendAllInOneChunk =>
      let size = buffer->Array.length
      if size > 0 {
        let commandsToSend = buffer->Array.toSpliced(~start=0, ~remove=size, ~insert=[])
        let promise = Config.publishCommands(Spec.name, commandsToSend->toJsons)
        running := Some(promise)
        switch await promise {
        | () =>
          EffectLogger.logDebug(
            ~comp="CommandPublisher",
            `send: finished SendAllInOneChunk: ${size->Int.toString}`,
          )->Effect.runSync
        | exception JsExn(e) =>
          let errMsg = e->JsExn.message->Option.getOr("unknown")
          EffectLogger.logError(
            ~comp="CommandPublisher",
            `send error: couldn't publish ${size->Int.toString} commands: ${errMsg}`,
          )->Effect.runSync
        }
        running := None
      }
    }
  }

  let publish = (id: string, command: Spec.command) => {
    let _ = buffer->Array.push((id, command))
    switch (running.contents, Config.mode) {
    | (None, SendChunks(chunkSize)) if buffer->Array.length >= chunkSize =>
      running := Some(Promise.resolve())
      let _ = send()
    | _ => ()
    }
  }

  let clear = () => {
    EffectLogger.logDebug(~comp="CommandPublisher", "clear")->Effect.runSync
    let _ = buffer->Array.removeInPlace(0)
    flush := false
  }

  let flush = async () => {
    EffectLogger.logDebug(~comp="CommandPublisher", "flush")->Effect.runSync
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
