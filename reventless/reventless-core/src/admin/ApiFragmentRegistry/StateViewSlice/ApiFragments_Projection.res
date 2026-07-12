@@reventless.projection

// A fragment change resets the row to "pending" — the automation's push outcome for the
// new fragment arrives as a subsequent ApiFragmentPushRecorded. The Update on a deleted
// row (a push recorded after deregistration) is a no-op by Update semantics.
let project = event =>
  switch event {
  | ApiFragmentRegistered({pluginId, fragment, apiTarget, at}) => [
      Set(
        pluginId,
        {
          pluginId,
          encoded: fragment.encoded,
          protocol: fragment.protocol,
          apiTarget,
          registeredAt: at,
          updatedAt: at,
          pushStatus: "pending",
          pushMessage: "",
          pushedAt: "",
        },
      ),
    ]
  | ApiFragmentUpdated({pluginId, newFragment, apiTarget, at}) => [
      Update(
        pluginId,
        state => {
          ...state,
          encoded: newFragment.encoded,
          protocol: newFragment.protocol,
          apiTarget,
          updatedAt: at,
          pushStatus: "pending",
          pushMessage: "",
        },
      ),
    ]
  | ApiFragmentDeregistered({pluginId}) => [Delete(pluginId)]
  | ApiFragmentPushRecorded({pluginId, ok, message, at}) => [
      Update(
        pluginId,
        state => {
          ...state,
          pushStatus: ok ? "ok" : "error",
          pushMessage: message,
          pushedAt: at,
        },
      ),
    ]
  }
