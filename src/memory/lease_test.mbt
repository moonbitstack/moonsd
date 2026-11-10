// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The parts of the in-process registry a conversation with a real backend would
// hide: what a sweep does to a whole generation of leases, what a restored registry
// does with a clock, and the order in which a watcher is told about changes.

///|
fn endpoint(n : Int32) -> @moonsd.Endpoint {
  @moonsd.Endpoint::new("10.0.0.\{n}", 9000 + n)
}

///|
async test "a sweep ends every lease past its time, and the watcher hears it once" {
  let now = Ref(0L)
  let registry = @memory.Registry::new(now=() => now.val)
  registry.register("a", endpoint(1), 100) |> ignore
  registry.register("a", endpoint(2), 100) |> ignore
  registry.register("b", endpoint(3), 100) |> ignore
  let watcher = registry.watch("a")
  let first = watcher.next()
  assert_eq(first.endpoints.length(), 2)
  now.val = 100L
  registry.sweep()
  assert_eq(registry.resolve("a").length(), 0)
  assert_eq(registry.resolve("b").length(), 0)
  let after = watcher.next()
  assert_eq(after.endpoints.length(), 0)
  assert_true(after.revision > first.revision)
  watcher.close()
}

///|
async test "a registry that outlives its snapshot holds what was written" {
  let now = Ref(0L)
  let live = @memory.Registry::new(now=() => now.val)
  live.register("web", endpoint(1), 100) |> ignore
  let text = live.snapshot()
  now.val = 1000L
  assert_eq(live.resolve("web").length(), 0)
  // Restored entries have no lease to renew and no clock to end them: whoever
  // registered them registers again.
  let back = @memory.Registry::restore(text, now=() => now.val)
  assert_eq(back.resolve("web").length(), 1)
  now.val = 60_000L
  back.sweep()
  assert_eq(back.resolve("web").length(), 1)
}

///|
async test "a service with no endpoint left is not listed" {
  let registry = @memory.Registry::new()
  let lease = registry.register("web", endpoint(1), 100)
  registry.register("api", endpoint(2), 100) |> ignore
  assert_eq(registry.services().length(), 2)
  registry.deregister(lease)
  assert_eq(registry.services(), ["api"])
}

///|
async test "a watcher hears every change, in the order they happened" {
  let registry = @memory.Registry::new()
  let watcher = registry.watch("web")
  let empty = watcher.next()
  assert_eq(empty.endpoints.length(), 0)
  let first = registry.register("web", endpoint(1), 100)
  registry.register("web", endpoint(2), 100) |> ignore
  registry.deregister(first)
  let one = watcher.next()
  assert_eq(one.endpoints.length(), 1)
  let two = watcher.next()
  assert_eq(two.endpoints.length(), 2)
  let back = watcher.next()
  assert_eq(back.endpoints.length(), 1)
  assert_true(back.revision > two.revision && two.revision > one.revision)
  watcher.close()
}

///|
async test "an empty registry writes a snapshot that brings back an empty registry" {
  let registry = @memory.Registry::new()
  let back = @memory.Registry::restore(registry.snapshot())
  assert_eq(back.services(), [])
  assert_eq(back.revision(), 0L)
  assert_eq(back.resolve("anything").length(), 0)
}
