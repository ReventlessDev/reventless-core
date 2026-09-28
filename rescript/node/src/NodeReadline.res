/** Bindings for [`node:readline/promises`](https://nodejs.org/api/readline.html#promises-api):
    asking a question on a terminal and awaiting the answer.

    The promise form, for a prompt that reads one answer at a time. A stream read
    line by line is {!NodeStreams.Readline}. The interface holds stdin open, so
    close it once the last answer is in or the process will not exit. */
type t

type options = {input: NodeProcess.stream, output: NodeProcess.stream}

@module("node:readline/promises")
external createInterface: options => t = "createInterface"

/** Writes the question to `output` and resolves with the line typed in reply,
    without its line ending. */
@send
external question: (t, string) => promise<string> = "question"

/** The prompt {!prompt} writes, and redraws when a terminal refreshes the line. */
@send
external setPrompt: (t, string) => unit = "setPrompt"

@send
external prompt: t => unit = "prompt"

/** Every line read, as it arrives, whether or not a {!question} is waiting for it.
    Piped input arrives all at once, before a second question could listen, so a
    prompt that asks several questions reads them from here. */
@send
external onLine: (t, @as("line") _, string => unit) => unit = "on"

/** Input has ended (the pipe closed, or Ctrl-D), or the interface was closed. */
@send
external onClose: (t, @as("close") _, unit => unit) => unit = "on"

@send
external close: t => unit = "close"
