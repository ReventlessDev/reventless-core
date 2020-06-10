open Jest;

describe("Message should", () =>
  Expect.(
    test("create a valid sequenceNr", () => {
      let now = 123456789.;
      let hrtime = (1, 1);
      expect(Message.hrtimeToString(~hrtime, ~now))
      |> toBe("123456789-000000001");
    })
  )
);