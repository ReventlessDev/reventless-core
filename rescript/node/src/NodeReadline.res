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

@send
external close: t => unit = "close"
