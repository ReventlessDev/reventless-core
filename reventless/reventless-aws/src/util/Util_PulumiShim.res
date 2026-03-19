type rec fakeOutput = {get: unit => string, apply: (string => string) => fakeOutput}

let rec val = value => {
  get: () => value,
  apply: fn => val(fn(value)),
}

type fakeResource = {
  name: fakeOutput,
  id: fakeOutput,
  urn: fakeOutput,
  service: fakeOutput,
  info: fakeOutput,
}

let resource = (~name, ~arn, ~service="unknown") => {
  name: val(name),
  id: val(name),
  urn: val(arn),
  service: val(service),
  info: val(""),
}

type fakeSqsQueue = {url: fakeOutput}

let sqsQueue = queueUrl => {
  url: val(queueUrl),
}
