// Bindings for Amazon Location Service (`@aws-sdk/client-location`).
//
// Both callers of this service want different things from the same call, which
// is why the bindings live here rather than inside either of them: the browser's
// geocoder Function URL wants a best-effort list to show a human, and an
// unattended translator wants to know *how sure* the service is before it writes
// a coordinate into an event log.

type client

module Raw = {
  @module("@aws-sdk/client-location") @new
  external client: unit => client = "LocationClient"
}

let clientInstance = ref(None)

let client = () => {
  switch clientInstance.contents {
  | None =>
    let c = Raw.client()
    clientInstance := Some(c)
    c
  | Some(c) => c
  }
}

module SearchPlaceIndexForTextCommand = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/location/command/SearchPlaceIndexForTextCommand/ */

  type t

  /** GeoJSON order — `[lng, lat]`, longitude first. Read it through
      `Geometry.point` rather than indexing it at a call site; the order is the
      single most reliable source of wrong-hemisphere markers in this domain. */
  type point = array<float>

  type geometry = {@as("Point") point?: point}

  type place = {
    @as("Label") label?: string,
    @as("Geometry") geometry?: geometry,
    @as("Country") country?: string,
    @as("PostalCode") postalCode?: string,
    @as("Municipality") municipality?: string,
  }

  type result = {
    @as("Place") place?: place,
    /** How well this result matches the query, 0…1 — present on results from
        Esri and HERE index configurations and absent on some others, which is
        why it is optional rather than defaulted. A caller that treats an absent
        relevance as a perfect match is asserting something the service did not
        say. */
    @as("Relevance") relevance?: float,
  }

  type input = {
    @as("IndexName") indexName: string,
    @as("Text") text: string,
    @as("MaxResults") maxResults?: int,
    @as("Language") language?: string,
    @as("FilterCountries") filterCountries?: array<string>,
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("Results") results?: array<result>,
  }

  @new @module("@aws-sdk/client-location")
  external make: input => t = "SearchPlaceIndexForTextCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = input => Raw.send(client(), input)
}
