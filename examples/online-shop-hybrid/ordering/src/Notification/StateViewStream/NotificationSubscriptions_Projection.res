@@reventless.projection

module Rules = TraitNotification.Notification_Rules
module Host = NotificationPreferences_Behavior

let categories: array<NotificationPreferences.category> = [
  OrderConfirmation,
  ShippingUpdate,
  Marketing,
]

// The full grid at its default setting, read from the same posture the write
// side decides with — so a posture changed there changes here, and the screen
// cannot show a switch that means something else when it is used.
//
// `deliverable` is asked of a directory holding only the announced address,
// because that is what a freshly announced recipient has. The cells it marks
// undeliverable are the ones no address exists for at all, which is a property of
// the channel today rather than of this recipient.
let defaultMatrix = email => {
  let announced = Rules.empty->Rules.evolve(Announced({channel: Email, address: email}))
  categories->Array.flatMap(category =>
    Rules.channels->Array.map(channel => {
      NotificationSubscriptions.category,
      channel: Host.channelOf(channel),
      enabled: Host.posture(Host.categoryKey(category), channel),
      deliverable: announced->Rules.addressFor(channel)->Option.isSome,
    })
  )
}

let withCell = (state: NotificationSubscriptions.state, category, channel, enabled) => {
  ...state,
  subscriptions: state.subscriptions->Array.map(s =>
    s.category == category && s.channel == channel ? {...s, enabled} : s
  ),
}

let project = ({event, _}) =>
  switch event {
  // `UpdateWithDefault`, because an announcement is repeated every time the host
  // says where a recipient is: the first one builds the grid, and a later address
  // change must not reset the choices they have made since.
  | RecipientAnnounced({recipientId, email}) => [
      UpdateWithDefault(
        recipientId,
        {
          NotificationSubscriptions.recipientId,
          email,
          subscriptions: defaultMatrix(email),
        },
        state => {...state, email},
      ),
    ]
  | NotificationSubscribed({recipientId, category, channel}) => [
      Update(recipientId, state => withCell(state, category, channel, true)),
    ]
  | NotificationUnsubscribed({recipientId, category, channel}) => [
      Update(recipientId, state => withCell(state, category, channel, false)),
    ]
  }
