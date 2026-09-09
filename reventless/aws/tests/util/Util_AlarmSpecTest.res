open JestGlobals

module M = ReventlessCore.Monitoring
module A = Util_AlarmSpec

describe("Util_AlarmSpec", () => {
  testSync("every kind alarms on Errors by default", () => {
    [M.CommandHandler, Projection, Reactor, EventCollector, Task, Other("Counter")]->Array.forEach(
      kind => {
        let specs = A.forKind(~kind)
        expect(specs->Array.length)->toBe(1)
        let spec = specs->Array.getUnsafe(0)
        expect(spec.metricName)->toBe("Errors")
        expect(spec.comparisonOperator)->toBe("GreaterThanOrEqualToThreshold")
        // An idle stack publishes no datapoints, and "no traffic" must not read as
        // a failure — an alarm permanently in ALARM teaches everyone to ignore it.
        expect(spec.treatMissingData)->toBe("notBreaching")
      },
    )
  })

  // The handler fails on every delivery on purpose, so Errors says only that it is
  // doing its job. That it ran at all is the incident.
  testSync("a dead-letter sink alarms on Invocations, not Errors", () => {
    let specs = A.forKind(~kind=DeadLetterSink)
    expect(specs->Array.length)->toBe(1)
    expect((specs->Array.getUnsafe(0)).metricName)->toBe("Invocations")
  })

  // The case that went unnoticed on a deployed estate: a heartbeat that stops
  // emits no errors AND no invocations, so nothing an Errors alarm can see.
  testSync(
    "a scheduler also alarms on its own silence, and that alarm treats missing data as breaching",
    () => {
      let specs = A.forKind(~kind=Scheduler, ~silenceWindowSeconds=1800)
      expect(specs->Array.length)->toBe(2)

      let silence = specs->Array.getUnsafe(1)
      expect(silence.metricName)->toBe("Invocations")
      expect(silence.comparisonOperator)->toBe("LessThanThreshold")
      expect(silence.period)->toBe(1800)
      expect(silence.treatMissingData)->toBe("breaching")
      // Distinct suffix, or the two alarms would collide on one resource name.
      expect(silence.suffix)->toBe("Silent")
      expect(silence.meaning)->toBe("has not run for 30 minutes")
    },
  )

  testSync("the silence window defaults to an hour — twelve missed heartbeats", () => {
    let silence = A.forKind(~kind=Scheduler)->Array.getUnsafe(1)
    expect(silence.period)->toBe(3600)
  })

  testSync(
    "resource names separate a unit's alarms, and like-named components of different plugins",
    () => {
      let specs = A.forKind(~kind=Scheduler)
      let nameFor = (spec: A.t, ~plugin) =>
        A.resourceName(~kind=Scheduler, ~name="Heartbeat", ~plugin, ~suffix=spec.suffix)

      expect(nameFor(specs->Array.getUnsafe(0), ~plugin=Some("Catalog")))->toBe(
        "alarm-scheduler-Catalog-Heartbeat",
      )
      expect(nameFor(specs->Array.getUnsafe(1), ~plugin=Some("Catalog")))->toBe(
        "alarm-scheduler-Catalog-HeartbeatSilent",
      )
      // Two plugins can own like-named components; without the plugin these collide.
      expect(nameFor(specs->Array.getUnsafe(0), ~plugin=Some("Ordering")))->toBe(
        "alarm-scheduler-Ordering-Heartbeat",
      )
      // Platform substrate belongs to no plugin.
      expect(
        A.resourceName(~kind=DeadLetterSink, ~name="DeadLetterQueue", ~plugin=None, ~suffix=""),
      )->toBe("alarm-deadlettersink-DeadLetterQueue")
    },
  )

  // A state-change message carries the description and neither the tags nor the
  // name, so everything a reader or a parser needs has to be in this one string.
  testSync("the description names the unit for a person and carries a machine token", () => {
    let spec = A.forKind(~kind=CommandHandler)->Array.getUnsafe(0)
    let desc = A.description(
      ~kind=CommandHandler,
      ~name="AllAggregatesCmdHandler",
      ~plugin=Some("Ordering"),
      ~platform=Some("online-shop"),
      ~spec,
      ~logs=Some("/aws/lambda/online-shop-AllAggregatesCmdHandler"),
    )
    expect(
      desc->String.includes("'AllAggregatesCmdHandler' (plugin Ordering, platform online-shop)"),
    )->toBe(true)
    expect(desc->String.includes("Logs: /aws/lambda/online-shop-AllAggregatesCmdHandler."))->toBe(
      true,
    )
    expect(
      desc->String.includes(
        "[reventless plugin=Ordering platform=online-shop component=AllAggregatesCmdHandler kind=commandhandler]",
      ),
    )->toBe(true)
  })

  testSync(
    "a unit owned by no plugin claims none, and one with no logs promises no address",
    () => {
      let spec = A.forKind(~kind=DeadLetterSink)->Array.getUnsafe(0)
      let desc = A.description(
        ~kind=DeadLetterSink,
        ~name="DeadLetterQueue",
        ~plugin=None,
        ~platform=None,
        ~spec,
        ~logs=None,
      )
      // A dead-letter queue is shared by every plugin in the estate — naming one
      // would be a lie, and an empty parenthesis is noise.
      expect(desc->String.includes("(plugin"))->toBe(false)
      expect(desc->String.includes("Logs:"))->toBe(false)
      expect(desc->String.includes("kind=deadlettersink"))->toBe(true)
    },
  )
})
