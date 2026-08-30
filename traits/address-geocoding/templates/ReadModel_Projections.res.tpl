// Scaffold: the read-model contribution. One `Reventless.Geolocation.t` field on the
// view's state — `geolocation: Reventless.Geolocation.t` — and these projection arms.
// Three arms rather than `option<GeoPoint.t>`: `Pending` carries the {{subject}}
// asked about, so a stale answer is detectable from the row alone.

      | {{Created}}({ {{subject}} }) => /* … */ geolocation: Pending({requestedFor: {{subject}} })
      // A new {{subject}} invalidates the pin: back to Pending for the new one.
      | {{Subject}}Updated({ {{subject}} }) =>
        Update(id, state => {...state, {{subject}}, geolocation: Pending({requestedFor: {{subject}} })})
      | LocationSet({location}) =>
        Update(id, state => {...state, geolocation: Located({point: location})})
      // The client supplied the pair, so no geocode is owed.
      | {{Subject}}Located({ {{subject}}, location}) =>
        Update(id, state => {...state, {{subject}}, geolocation: Located({point: location})})
      | {{Subject}}Unresolvable({reason}) =>
        Update(id, state => {...state, geolocation: Unresolvable({reason: reason})})
