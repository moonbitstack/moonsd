---
name: moonconsul
description: "A Consul client for MoonBit: register services and checks, read and write KV pairs with compare-and-swap, take distributed locks and semaphores, watch the cluster for changes, and manage ACLs, prepared queries, config entries and Connect. Use it when a MoonBit service has to join or query a Consul cluster."
---

# moonconsul

Install the module, then import the packages it calls: the root package holds
the API groups and the `Transport` trait, `fetch` carries requests over a real
connection, and `concurrency` holds what waits.

```
moon add moonbitstack/moonconsul
```

```moonbit
import {
  "moonbitstack/moonconsul",
  "moonbitstack/moonconsul/fetch",
  "moonbitstack/moonconsul/concurrency",
}
```

## Connect to an agent

`default_config` is `http://127.0.0.1:8500` with no token; override what differs.
One client is safe to share between tasks.

```mbt native
let client = @fetch.connect(config={
  ..@moonconsul.default_config,
  address: "127.0.0.1:8500",
  token: Some("moonconsul-root"),
})
ignore(client.status().leader())
```

## Register a service and keep its check passing

A service registered with an inline TTL check starts `critical`, and its own
check is named `service:<id>`; pass the check to make the instance healthy.

```mbt native
ignore(
  client
  .agent()
  .service_register({
    ..@moonconsul.default_service_registration,
    id: Some("web-1"),
    name: "web",
    port: Some(8080),
    tags: Some(["blue"]),
    check: Some({
      ..@moonconsul.default_service_check,
      ttl: Some("30s"),
      status: Some("critical"),
    }),
  }),
)
ignore(client.agent().check_pass("service:web-1"))
let (instances, _) = client.health().service("web", passing=true)
println("\{instances.length()} passing instance(s)")
```

`service_deregister(id)` takes the instance out again. An id may hold a space or
a slash: every id goes into the path percent-encoded, so `web 1/eu` reaches the
agent as one segment and comes back as the same id.

## Take a lock instead of hand-rolling one

`Lock` and `Semaphore` run the protocol of `consul lock` and `consul lock -n`,
so they exclude a lock that command holds. `hold` renews the session while the
body runs and gives the lock back afterwards; if the lock is lost, the body is
cancelled and `hold` raises `Conflict`.

```mbt native
let lock = @concurrency.Lock::new(client, "jobs/nightly")
lock.hold(() => println("the job ran with the lock"))

let seats = @concurrency.Semaphore::new(client, "jobs/workers", 4)
seats.hold(() => println("a worker took one of four seats"))
```

Cancelling the task gives up a wait, so `@async.with_timeout` bounds one. Pass
`session` to run on a session of your own, which then stays yours to renew and
destroy.

## Follow a value

`poll` is one blocking read: pass `wait_index` and `wait_time`, and feed its
`last_index` into the next call. `@concurrency.watch` is that loop, running
until its task is cancelled, calling the handler only when the value changes.

```mbt native
let (value, meta) = client.poll(@moonconsul.Key("config/theme"), options={
  ..@moonconsul.default_query_options,
  wait_index: Some(0UL),
  wait_time: Some(60_000_000_000L),
})
match value {
  Some(seen) => println("index \{meta.last_index}: \{seen.stringify()}")
  None => println("the key is absent")
}
```

## Rules that catch people out

- Reads return `(value, QueryMeta)`; writes return `WriteMeta`. Everything raises
  `Refused`, and a missing key, session or entry is `Refused::NotFound`.
- `lock_delay` is in nanoseconds, and the agent reads a value under 1000 as
  seconds — write `Some(0)` for no delay, not `Some(1)`.
- `acquire` and `release` take a session; without one they are refused. A key
  held by a session goes when the session dies, which is why a lock is a session
  and a key rather than a flag.
- Compare-and-swap needs the index the pair came with: write `modify_index` back
  unchanged. A `cas` with a stale index returns `false` rather than raising.
- `QueryOptions.filter` is an expression the agent evaluates, such as
  `Service == "web"`; it is neither a prefix match nor a regular expression.
- The namespace travels in the query of a write; an agent without namespaces
  refuses a body that carries one, so set `ns` on the options rather than in a
  registration's JSON.
