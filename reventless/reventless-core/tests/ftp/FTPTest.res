open JestGlobals
open FTP

describe("FTP.SSH2 should", () => {
  testSync("parse valid url, only url given", () => {
    let t = "example.com"->parseUrl
    let res = ("example.com", None, "")
    expect(t)->toEqual(res)
  })

  testSync("parse valid url, url and relative path given", () => {
    let t = "example.com/some/path"->parseUrl
    let res = ("example.com", None, "some/path")
    expect(t)->toEqual(res)
  })

  testSync("parse valid url, url and absolute path given", () => {
    let t = "example.com//some/path"->parseUrl
    let res = ("example.com", None, "/some/path")
    expect(t)->toEqual(res)
  })

  testSync("parse valid url, url and port given", () => {
    let t = "example.com:8080"->parseUrl
    let res = ("example.com", Some(8080), "")
    expect(t)->toEqual(res)
  })

  testSync("parse valid url, all parts given (relative path)", () => {
    let t = "reventless.example.com:8025/some/path"->parseUrl
    let res = ("reventless.example.com", Some(8025), "some/path")
    expect(t)->toEqual(res)
  })

  testSync("parse valid url, all parts given (absolute path)", () => {
    let t = "reventless.example.com:8025//some/path"->parseUrl
    let res = ("reventless.example.com", Some(8025), "/some/path")
    expect(t)->toEqual(res)
  })

  testSync("parse valid url, all parts given (relative path first)", () => {
    let t = "example.com/some/path:8080"->parseUrl
    let res = ("example.com", Some(8080), "some/path")
    expect(t)->toEqual(res)
  })

  testSync("parse valid url, all parts given (absolute path first)", () => {
    let t = "example.com//some/path:8080"->parseUrl
    let res = ("example.com", Some(8080), "/some/path")
    expect(t)->toEqual(res)
  })

  testSync("parse url with invalid port (relative path)", () => {
    let t = "example.com/some/path:invalidPort"->parseUrl
    let res = ("example.com", None, "some/path")
    expect(t)->toEqual(res)
  })

  testSync("parse url with invalid port (absolute path)", () => {
    let t = "example.com//some/path:invalidPort"->parseUrl
    let res = ("example.com", None, "/some/path")
    expect(t)->toEqual(res)
  })
})
