// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn ms_clock() -> () -> Int64 {
  () => @env.now().reinterpret_as_int64()
}

///|
async test "the in-memory registry keeps the contract" {
  let registry = @memory.Registry::new()
  @conformance.check(registry, registry, expiry=false)
}

///|
async test "with a clock it keeps the contract, leases ending included" {
  let registry = @memory.Registry::new(now=ms_clock())
  @conformance.check(registry, registry)
}

///|
async test "a lease ends when the clock passes it, renewing moves that on" {
  let now = Ref(0L)
  let registry = @memory.Registry::new(now=() => now.val)
  let lease = registry.register("s", @moonsd.Endpoint::new("h", 1), 100)
  now.val = 60L
  registry.renew(lease)
  now.val = 120L
  assert_eq(registry.resolve("s").length(), 1)
  now.val = 160L
  assert_eq(registry.resolve("s").length(), 0)
  let refused = try registry.renew(lease) catch {
    @moonsd.Refused::Expired(_) => true
    _ => false
  } noraise {
    _ => false
  }
  assert_true(refused)
}

///|
async test "registering an id again replaces it, and the old lease is spent" {
  let registry = @memory.Registry::new()
  let old = registry.register("s", @moonsd.Endpoint::new("h", 1, id="a"), 100)
  let fresh = registry.register("s", @moonsd.Endpoint::new("h", 2, id="a"), 100)
  let got = registry.resolve("s")
  assert_eq(got.length(), 1)
  assert_eq(got[0].port, 2)
  registry.deregister(old)
  assert_eq(registry.resolve("s").length(), 1)
  registry.deregister(fresh)
  assert_eq(registry.resolve("s").length(), 0)
}

///|
async test "a spent lease cannot renew an id someone else has registered" {
  let registry = @memory.Registry::new()
  let old = registry.register("s", @moonsd.Endpoint::new("h", 1, id="a"), 100)
  let fresh = registry.register("s", @moonsd.Endpoint::new("h", 2, id="a"), 100)
  let refused = try registry.renew(old) catch {
    @moonsd.Refused::Expired(_) => true
    _ => false
  } noraise {
    _ => false
  }
  assert_true(refused)
  assert_eq(registry.resolve("s"), [fresh.endpoint])
}

///|
async test "a snapshot brings back the services and the revision" {
  let registry = @memory.Registry::new()
  let kept = @moonsd.Endpoint::new(
    "::1",
    80,
    id="a",
    weight=2,
    metadata=Map([("zone", "z")]),
  )
  registry.register("web", kept, 100) |> ignore
  let gone = registry.register("old", @moonsd.Endpoint::new("h", 1), 100)
  registry.deregister(gone)
  let back = @memory.Registry::restore(registry.snapshot())
  assert_eq(back.services(), ["web"])
  assert_eq(back.resolve("web"), [kept])
  assert_eq(back.revision(), registry.revision())
  for bad in ["", "[]", "{\"revision\":1}", "{\"revision\":1,\"services\":3}"] {
    let refused = try @memory.Registry::restore(bad) catch {
      @moonsd.Refused::Malformed(_) => true
      _ => false
    } noraise {
      _ => false
    }
    assert_true(refused)
  }
}

///|
async test "an empty register writes a snapshot and comes back from it" {
  let registry = @memory.Registry::new()
  let text = registry.snapshot()
  assert_eq(text, "{\"revision\":0,\"services\":{}}")
  let back = @memory.Registry::restore(text)
  assert_eq(back.services(), [])
  assert_eq(back.revision(), 0L)
}

///|
async test "a revision too large for a double keeps its digits across a snapshot" {
  // One past 2^53, where the nearest double is a different number.
  let registry = @memory.Registry::restore(
    "{\"revision\":9007199254740993,\"services\":{}}",
  )
  assert_eq(registry.revision(), 9007199254740993L)
  assert_true(registry.snapshot().contains("9007199254740993"))
  let back = @memory.Registry::restore(registry.snapshot())
  assert_eq(back.revision(), 9007199254740993L)
}

///|
async test "a snapshot that is not one value, or whose revision is fractional, is refused" {
  for
    bad in [
      "{\"revision\":1,\"services\":{}} {}", "{\"revision\":1.5,\"services\":{}}",
      "{\"revision\":\"1\",\"services\":{}}", "{\"revision\":1,\"services\":null}",
    ] {
    let refused = try @memory.Registry::restore(bad) catch {
      @moonsd.Refused::Malformed(_) => true
      _ => false
    } noraise {
      _ => false
    }
    assert_true(refused)
  }
}

///|
async test "closing a watcher ends it and stops feeding it" {
  let registry = @memory.Registry::new()
  let watcher = registry.watch("s")
  assert_eq(watcher.next().endpoints.length(), 0)
  watcher.close()
  registry.register("s", @moonsd.Endpoint::new("h", 1), 100) |> ignore
  let ended = try {
    watcher.next() |> ignore
    false
  } catch {
    _ => true
  }
  assert_true(ended)
}
