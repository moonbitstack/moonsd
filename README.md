<div align="center">

# moonsd

**The register of what is alive.** A service says it is here, keeps saying it, and is found.
moonsd writes that down as three traits, and leaves every registry to implement them.

<a href="https://moonbitstack.github.io/moonsd/">Site</a> ·
<a href="https://moonbitstack.github.io/moonsd/guide.html">Guide</a> ·
<a href="https://moonbitstack.github.io/moonsd/api.html">API</a> ·
<a href="https://mooncakes.io/docs/moonbitstack/moonsd">mooncakes</a>

</div>

---

```mbt native
async fn greeter(registry : @memory.Registry) -> Unit {
  @async.with_task_group(group => {
    // A service announces itself for as long as this task runs, and leaves on the way out.
    group.spawn_bg(() =>
      @moonsd.hold(registry, "greeter", @moonsd.Endpoint::new("10.0.0.1", 12000))
    )

    // A caller follows the service in one task and reads the list on the request path.
    let view = @moonsd.View::new()
    group.spawn_bg(() => view.follow(registry, "greeter"))
    @async.sleep(50)
    println(view.endpoints().map(e => e.address()).join(", "))
  })
}
```

## Install

```
moon add moonbitstack/moonsd
```

Then the client for the registry you run: `moonbitstack/moonredis`, `moonbitstack/moonetcd` or
`moonbitstack/moonconsul`. Every one of them implements the same three traits, so the code above
runs unchanged on all of them; `moonsd/memory` runs it inside a test.

## The contract

| Trait | Methods | What it promises |
|:--:|:--|:--|
| `Registrar` | `register`, `renew`, `deregister` | An endpoint is known for `ttl` milliseconds from its last renewal. `renew` raises `Refused::Expired` once the registry has let it go; `deregister` is harmless on a lease already gone. |
| `Discovery` | `resolve`, `watch` | `resolve` answers once, and an unknown service has no endpoints. |
| `Watcher` | `next`, `close` | The first `next` gives the service as it stands; each later one waits for a change. |

A watcher gives whole snapshots, not events. A backend that lost its connection reconnects, one
whose history was compacted starts again, and neither is the caller's business: what comes out is
always what is true now.

`hold` and `View` are written once, against the traits. `hold` renews every `renew_after(ttl)`
milliseconds — a third of the lease — and rides out a registry that goes away: the failure goes to
`report`, and the endpoint registers again when the registry is back. `View::follow` keeps the last
list when a watcher fails, since a stale list beats none, and watches again after `retry`
milliseconds.

## Packages

| Package | Contents |
|:--:|:--|
| `moonsd` | `Endpoint`, `Lease`, `Update`, `Refused`, the three traits, `hold`, `renew_after`, `View` |
| `moonsd/memory` | `Registry`, the contract in this process: leases when given a clock, revisions, `snapshot` and `restore` |
| `moonsd/conformance` | `check`, every behaviour the contract promises, run against any backend |

## Backends

Each backend is a full client for its registry, published as its own module from `drivers/` in this
repository; its `sd` package is the part that implements the contract.

| Module | Directory | `sd` package | Page |
|:--:|:--:|:--|:--|
| `moonbitstack/moonredis` | [`drivers/redis`](drivers/redis) | Keys that expire, watched by reading again | [redis](https://moonbitstack.github.io/moonsd/redis.html) |
| `moonbitstack/moonetcd` | [`drivers/etcd`](drivers/etcd) | Keys on leases, watched by revision | [etcd](https://moonbitstack.github.io/moonsd/etcd.html) |
| `moonbitstack/moonconsul` | [`drivers/consul`](drivers/consul) | Services with ttl checks, watched by blocking queries | [consul](https://moonbitstack.github.io/moonsd/consul.html) |

## Writing a backend

Implement `Registrar` and `Discovery`, and call `check` from your tests against a real server:

<!-- nocheck -->
```moonbit
async test "my backend keeps the contract" {
  let backend = connect()
  @conformance.check(backend, backend)
}
```

`check` asks only that a change shows up within `settle` milliseconds, so an eventually consistent
backend passes. Pass `expiry=false` for a backend whose leases do not end on their own. It registers
and removes everything it touches under one unused service name.

## Consistency

There is no standards body for service discovery, so the authority for this contract is the servers
themselves plus one suite that every implementation runs. `conformance.check` is that suite: it is
run against `moonsd/memory` (with and without a clock) and against each backend on a live server,
and it fails on the first behaviour a backend breaks, naming it.

| Backend | Verified against | What the suite covers |
|:--:|:--|:--|
| `moonsd/memory` | itself, on every target | the round trip, removal, `Expired` on a spent lease, a watcher's arrival, departure and empty service, `hold` with `View`, and a lease left to lapse |
| `moonredis` | Redis 8, standalone, cluster and sentinel | the same, with `Expired` coming from a key whose ttl ran out, and a watcher that sees the change on its next poll |
| `moonetcd` | etcd 3.5, one node and a three-node cluster with members killed | the same, with `Expired` coming from a keep-alive that reports no time left, and a watcher that resumes after a compaction |
| `moonconsul` | Consul 1.20, two agents | the same, with `Expired` coming from a ttl check that failed, and a watcher that follows a blocking query's index |

Behaviour that differs between registries, and is therefore stated rather than hidden:

- **How late a change may be.** Redis has no change feed a client can rely on, so a watcher reads
  the service again every `poll` milliseconds (a second by default). etcd and Consul push, so a
  change arrives with the registry's own latency.
- **When a lease ends.** Redis and etcd end it at the ttl. Consul takes the instance out of
  `resolve` as soon as the check fails, but keeps the registration for `reap_after` — a minute, the
  agent's minimum — before removing it.
- **The ttl's unit.** etcd leases last whole seconds and refuse a ttl below their minimum, so a
  millisecond ttl is rounded up: rounding down would end the lease early.
- **Targets.** `hold`, `View` and the backends' transports need an asynchronous runtime, so they run
  on native and js. On wasm-gc the types, the traits and `moonsd/memory` without a clock still
  compile and test.

## License

Apache-2.0.
