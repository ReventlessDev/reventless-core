// A message board's question: members post messages, reply under them, and mark
// one reply as the answer. The question decides by the message's id and reads the
// replies under it, which are stored under the reply: a pair.
//
// Hand-written `@s.matches(...)` markers: the reventless-ppx is not wired into
// this package (see `EpTestSlice`).

module Defaults = {
  type role = Reventless.Role.name
  let authorizationOf = (_: string): Reventless.Authorization.rule<role> => AllowAnonymous
  type lifecycleState = unit
  let traits: array<Reventless.Trait.t> = []
  let readConsistency = Reventless.ReadConsistency.EscalateOnRetry
}

module PostMessage = {
  include Defaults
  let name = "PostMessage"
  let moduleUrl = "question://src/Messages/StateChange/PostMessage.res.mjs"

  @schema
  type consumedEvent = MessagePosted({messageId: string})
  @schema
  type command = PostMessage({messageId: @s.matches(Reventless.DcbTag.string) string})
  @schema
  type error = AlreadyPosted
  @schema
  type event = MessagePosted({messageId: @s.matches(Reventless.DcbTag.partition) string})

  let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
}

module PostMessageDecision = {
  type state = bool
  let initialState = false
  let evolve = (_, _: PostMessage.consumedEvent) => true
  let decide = (posted, PostMessage.PostMessage({messageId})) =>
    posted
      ? Error(PostMessage.AlreadyPosted)
      : Ok([PostMessage.MessagePosted({messageId: messageId})])
  let moduleUrl = "question://PostMessageDecision"
}

module EditMessage = {
  include Defaults
  let name = "EditMessage"
  let moduleUrl = "question://src/Messages/StateChange/EditMessage.res.mjs"

  @schema
  type consumedEvent = MessagePosted({messageId: string}) | MessageEdited({messageId: string})
  @schema
  type command = EditMessage({messageId: @s.matches(Reventless.DcbTag.string) string, text: string})
  @schema
  type error = NoSuchMessage
  @schema
  type event =
    MessageEdited({messageId: @s.matches(Reventless.DcbTag.partition) string, text: string})

  let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
}

module EditMessageDecision = {
  type state = bool
  let initialState = false
  let evolve = (posted, event: EditMessage.consumedEvent) =>
    switch event {
    | MessagePosted(_) => true
    | MessageEdited(_) => posted
    }
  let decide = (posted, EditMessage.EditMessage({messageId, text})) =>
    posted ? Ok([EditMessage.MessageEdited({messageId, text})]) : Error(EditMessage.NoSuchMessage)
  let moduleUrl = "question://EditMessageDecision"
}

// A reply names its message without reading it, so it is stored under the reply.
module PostReply = {
  include Defaults
  let name = "PostReply"
  let moduleUrl = "question://src/Replies/StateChange/PostReply.res.mjs"

  @schema
  type consumedEvent = ReplyPosted({replyId: string})
  @schema
  type command =
    | PostReply({
        replyId: @s.matches(Reventless.DcbTag.string) string,
        messageId: @s.matches(Reventless.DcbTag.string) string,
      })
  @schema
  type error = AlreadyPosted
  @schema
  type event =
    | ReplyPosted({
        replyId: @s.matches(Reventless.DcbTag.partition) string,
        messageId: @s.matches(Reventless.DcbTag.string) string,
      })

  let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
}

module PostReplyDecision = {
  type state = bool
  let initialState = false
  let evolve = (_, _: PostReply.consumedEvent) => true
  let decide = (posted, PostReply.PostReply({replyId, messageId})) =>
    posted ? Error(PostReply.AlreadyPosted) : Ok([PostReply.ReplyPosted({replyId, messageId})])
  let moduleUrl = "question://PostReplyDecision"
}

// The question: one answer, and only a reply posted under it.
module QuestionState = {
  include Defaults
  let name = "QuestionState"
  let moduleUrl = "question://src/Questions/StateChange/QuestionState.res.mjs"

  @schema
  type consumedEvent =
    | MessagePosted({messageId: string})
    | ReplyPosted({replyId: string, messageId: @s.matches(Reventless.DcbTag.crossPartition) string})
    | AnswerMarked({messageId: string, replyId: string})
    | QuestionReopened({messageId: string})
  @schema
  type command =
    | MarkAnswer({
        messageId: @s.matches(Reventless.DcbTag.string) string,
        replyId: @s.matches(Reventless.DcbTag.string) string,
      })
    | ReopenQuestion({messageId: @s.matches(Reventless.DcbTag.string) string})
  @schema
  type error = NoSuchQuestion | NotAReplyHere | AlreadyAnswered | NotAnswered
  @schema
  type event =
    | AnswerMarked({
        messageId: @s.matches(Reventless.DcbTag.partition) string,
        replyId: @s.matches(Reventless.DcbTag.string) string,
      })
    | QuestionReopened({messageId: @s.matches(Reventless.DcbTag.partition) string})

  let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
}

module QuestionStateDecision = {
  type state = {posted: bool, replies: array<string>, answer?: string}
  let initialState = {posted: false, replies: []}
  let evolve = (state, event: QuestionState.consumedEvent) =>
    switch event {
    | MessagePosted(_) => {...state, posted: true}
    | ReplyPosted({replyId}) => {...state, replies: state.replies->Array.concat([replyId])}
    | AnswerMarked({replyId}) => {...state, answer: replyId}
    | QuestionReopened(_) => {...state, answer: ?None}
    }
  let decide = (state, command: QuestionState.command): result<
    array<QuestionState.event>,
    QuestionState.error,
  > =>
    switch command {
    | _ if !state.posted => Error(NoSuchQuestion)
    | MarkAnswer(_) if state.answer->Option.isSome => Error(AlreadyAnswered)
    | MarkAnswer({replyId}) if !(state.replies->Array.includes(replyId)) => Error(NotAReplyHere)
    | MarkAnswer({messageId, replyId}) => Ok([AnswerMarked({messageId, replyId})])
    | ReopenQuestion(_) if state.answer->Option.isNone => Error(NotAnswered)
    | ReopenQuestion({messageId}) => Ok([QuestionReopened({messageId: messageId})])
    }
  let moduleUrl = "question://QuestionStateDecision"
}
