open Jest;
open FTP;

describe("FTP.SSH2 should", () => {
  open Expect;
  test("parse valid url, only url given", () => {
    let t = "atos.net"->parseUrl;
    let res = ("atos.net", None, "");
    expect(t)->toEqual(res);
  });

  test("parse valid url, url and relative path given", () => {
    let t = "atos.net/some/path"->parseUrl;
    let res = ("atos.net", None, "some/path");
    expect(t)->toEqual(res);
  });

  test("parse valid url, url and absolute path given", () => {
    let t = "atos.net//some/path"->parseUrl;
    let res = ("atos.net", None, "/some/path");
    expect(t)->toEqual(res);
  });

  test("parse valid url, url and port given", () => {
    let t = "atos.net:8080"->parseUrl;
    let res = ("atos.net", Some(8080), "");
    expect(t)->toEqual(res);
  });

  test("parse valid url, all parts given (relative path)", () => {
    let t = "reventless.atos.net:8025/some/path"->parseUrl;
    let res = ("reventless.atos.net", Some(8025), "some/path");
    expect(t)->toEqual(res);
  });

  test("parse valid url, all parts given (absolute path)", () => {
    let t = "reventless.atos.net:8025//some/path"->parseUrl;
    let res = ("reventless.atos.net", Some(8025), "/some/path");
    expect(t)->toEqual(res);
  });

  test("parse valid url, all parts given (relative path first)", () => {
    let t = "atos.net/some/path:8080"->parseUrl;
    let res = ("atos.net", Some(8080), "some/path");
    expect(t)->toEqual(res);
  });

  test("parse valid url, all parts given (absolute path first)", () => {
    let t = "atos.net//some/path:8080"->parseUrl;
    let res = ("atos.net", Some(8080), "/some/path");
    expect(t)->toEqual(res);
  });

  test("parse url with invalid port (relative path)", () => {
    let t = "atos.net/some/path:invalidPort"->parseUrl;
    let res = ("atos.net", None, "some/path");
    expect(t)->toEqual(res);
  });

  test("parse url with invalid port (absolute path)", () => {
    let t = "atos.net//some/path:invalidPort"->parseUrl;
    let res = ("atos.net", None, "/some/path");
    expect(t)->toEqual(res);
  });
});
