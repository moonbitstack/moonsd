---
name: moonsd
description: "The service-discovery contract for MoonBit: register an endpoint and keep it alive with hold, follow a service and read its endpoints without waiting with View, test any backend with conformance.check. Backends for Redis, etcd and Consul ship in the same repository. Use it when a MoonBit service has to announce itself or find other services."
---

# moonsd

Install the contract, then the backend for the registry you run. The contract
has three packages: the root holds the types, the three traits, `hold` and
`View`; `memory` is a registry inside the process; `conformance` checks a
backend against the contract.

```
moon add moonbitstack/moonsd
```

```moonbit
import {
  "moonbitstack/moonsd",
  "moonbitstack/moonsd/memory",
  "moonbitlang/async",
}
```

| Registry | Module | Package |
|:--:|:--:|:--:|
| Redis | `moonbitstack/moonredis` | `moonredis/sd` |
| etcd | `moonbitstack/moonetcd` | `moonetcd/sd` |
| Consul | `moonbitstack/moonconsul` | `moonconsul/sd` |

Code written against `&Registrar` and `&Discovery` runs on any of them, and on
`@memory.Registry` in tests.

## Keep an endpoint registered

`hold` registers the endpoint, renews it at a third of `ttl`, and deregisters it
when its task is cancelled. A backend that goes away does not end it: the error
goes to `report`, and the endpoint registers again once the backend is back.

```mbt native
async fn serve(registry : &@moonsd.Registrar) -> Unit {
  let endpoint = @moonsd.Endpoint::new("10.0.0.1", 12000, metadata=Map([("zone", "a")]))
  @async.with_task_group(group => {
    group.spawn_bg(() => @moonsd.hold(registry, "greeter", endpoint, ttl=15_000))
    // serve requests here; leaving the group cancels hold, which deregisters
  })
}
```

## Read the endpoints on the request path

`View::follow` runs in its own task and keeps the latest list; `endpoints()`
reads it without waiting, so a load balancer can pick on every request. When a
watch fails, the view keeps the last list and watches again after `retry`
milliseconds.

```mbt native
async fn pick(discovery : &@moonsd.Discovery) -> Unit {
  let view = @moonsd.View::new()
  @async.with_task_group(group => {
    group.spawn_bg(() => view.follow(discovery, "greeter"))
    @async.sleep(50)
    let addresses = view.endpoints().map(e => e.address())
    println(addresses.join(", "))
  })
}
```

`resolve` asks once; `watch` gives a `&Watcher` whose first `next` is the
service as it stands and each later one waits for a change.

## Test with the registry in memory

`@memory.Registry` keeps the contract inside the process, with revisions and,
when given a clock, leases that expire. `snapshot` and `restore` save and load it
as JSON.

```mbt
async test "the greeter is found" {
  let registry = @memory.Registry::new()
  let lease = registry.register("greeter", @moonsd.Endpoint::new("10.0.0.1", 12000), 15_000)
  assert_eq(registry.resolve("greeter").length(), 1)
  registry.deregister(lease)
  assert_eq(registry.resolve("greeter").length(), 0)
}
```

## Write a backend

Implement `Registrar` (`register`, `renew`, `deregister`) and `Discovery`
(`resolve`, `watch`) with a `Watcher` (`next`, `close`), then run the
conformance check from a test against a real server. `hold`, `View` and every
framework built on the traits work with it unchanged.

```mbt nocheck
async test "my backend keeps the contract" {
  let backend = connect()
  @conformance.check(backend, backend)
}
```

## Rules that catch people out

- A watcher gives whole snapshots, never events: compare lists, do not apply
  deltas. Reconnects and compaction are the backend's business.
- `renew` raises `Refused::Expired` once the backend has let the lease go; `hold`
  handles that by registering again. `deregister` on a lease already gone is
  harmless.
- An unknown service resolves to an empty list, not an error.
- `ttl`, `retry` and `settle` are milliseconds; the presets are the public
  values `@moonsd.ttl`, `@moonsd.retry` and `@conformance.settle`.
- `conformance.check` waits up to `settle` for a change to show, so an
  eventually consistent backend passes; pass `expiry=false` for a backend whose
  leases never end.
