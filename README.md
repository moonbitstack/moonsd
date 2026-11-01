# moonsd

The contract of service discovery for MoonBit: what a registry does, and nothing about any one registry. A backend implements three small traits and gets the rest; a framework depends on the traits and works with every backend.

```moonbit
// A service keeps itself registered for as long as this task runs, and leaves on the way out.
group.spawn_bg(() => @moonsd.hold(registry, "greeter", @moonsd.Endpoint::new("10.0.0.1", 12000)))

// A caller follows the service in one task, and reads the list on the request path without waiting.
let view = @moonsd.View::new()
group.spawn_bg(() => view.follow(registry, "greeter"))
view.endpoints()
```

Run `moon run src/examples/tour --target native` for the whole surface in one go.

## The contract

| Trait | Methods | What it promises |
|:--:|:--|:--|
| `Registrar` | `register`, `renew`, `deregister` | An endpoint is known for `ttl` milliseconds from its last renewal. `renew` raises `Expired` once the backend has let it go; `deregister` is harmless on a lease already gone. |
| `Discovery` | `resolve`, `watch` | `resolve` answers once, and an unknown service has no endpoints. |
| `Watcher` | `next`, `close` | The first `next` gives the service as it stands; each later one waits for a change. |

A watcher gives whole snapshots, not events. A backend that lost its connection reconnects, one whose history was compacted starts again, and neither is the caller's business: what comes out is always what is true now.

`hold` and `View` are written once, against the traits. `hold` renews at a third of `ttl`, and rides out a backend that goes away: the failure goes to `report`, and the endpoint registers again when the backend is back. `View::follow` keeps the last list when a watcher fails, since a stale list beats none, and watches again after `retry` milliseconds.

## Packages

| Package | Contents |
|:--:|:--|
| `moonsd` | `Endpoint`, `Lease`, `Update`, `Refused`, the three traits, `hold`, `View` |
| `moonsd/memory` | `Registry`, the contract in this process: leases when given a clock, revisions, `snapshot` and `restore` |
| `moonsd/conformance` | `check`, every behaviour the contract promises, run against any backend |

## Backends

| Package | Backend |
|:--:|:--|
| `moonredis/sd` | Expiring keys, watched by reading again |
| `moonetcd/sd` | Keys on leases, watched by revision |

## Writing a backend

Implement `Registrar` and `Discovery`, and call `check` from your tests against a real server:

```moonbit
async test "my backend keeps the contract" {
  let backend = connect()
  @conformance.check(backend, backend)
}
```

`check` asks only that a change shows up within `settle` milliseconds, so an eventually consistent backend passes. Pass `expiry=false` for a backend whose leases do not end.

## License

Apache-2.0.
