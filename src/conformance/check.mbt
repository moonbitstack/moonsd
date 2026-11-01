// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How long a backend has to show a change, in milliseconds: a backend may be eventually
/// consistent, and these checks ask only that it gets there.
pub let settle : Int32 = 5000

///|
/// The lease the expiry check lets lapse, in milliseconds.
let short_ttl : Int32 = 1000

///|
/// How often `eventually` looks, in milliseconds.
let tick : Int32 = 25

///|
async fn eventually(
  settle : Int32,
  what : String,
  holds : async () -> Bool,
) -> Unit {
  let tries = settle / tick + 1
  for _ in 0..<tries {
    if holds() {
      return
    }
    @async.sleep(tick)
  }
  fail("not within \{settle} ms: " + what)
}

///|
fn has(list : Array[@moonsd.Endpoint], one : @moonsd.Endpoint) -> Bool {
  list.contains(one)
}

///|
fn ep(n : Int32) -> @moonsd.Endpoint {
  @moonsd.Endpoint::new(
    "10.0.0.\{n}",
    9000 + n,
    weight=n,
    metadata=Map([("zone", "z\{n}")]),
  )
}

///|
/// Run every behaviour the contract promises against one backend, under `service`, which must
/// be unused; everything it registers it removes. A backend's own test suite calls this against
/// a real server, so all backends are held to the same behaviour.
///
/// `expiry` covers a lease that is not renewed, which needs a backend that lets leases end.
/// Raises at the first behaviour that does not hold, naming it.
pub async fn check(
  registrar : &@moonsd.Registrar,
  discovery : &@moonsd.Discovery,
  service~ : String = "moonsd-conformance",
  settle~ : Int32 = settle,
  expiry~ : Bool = true,
) -> Unit {
  let ttl = @moonsd.ttl
  if discovery.resolve(service + "-unknown").length() != 0 {
    fail("a service nobody registered has endpoints")
  }
  // Registering, and what an endpoint carries through.
  let a = registrar.register(service, ep(1), ttl)
  let b = registrar.register(service, ep(2), ttl)
  eventually(settle, "two registered endpoints resolve, fields intact", () => {
    let got = discovery.resolve(service)
    got.length() == 2 && has(got, ep(1)) && has(got, ep(2))
  })
  // Renewing keeps an endpoint; removing one leaves the other.
  registrar.renew(a)
  registrar.deregister(b)
  eventually(settle, "a removed endpoint stops resolving", () => {
    let got = discovery.resolve(service)
    got.length() == 1 && has(got, ep(1))
  })
  registrar.deregister(b)
  let renewed = try registrar.renew(b) catch {
    @moonsd.Refused::Expired(_) => true
    _ => false
  } noraise {
    _ => false
  }
  if !renewed {
    fail("renewing a removed lease did not raise Expired")
  }
  // A watcher starts from the present, then follows.
  let watcher = discovery.watch(service)
  defer watcher.close()
  let first = watcher.next()
  if !has(first.endpoints, ep(1)) {
    fail("a watcher's first update is not the service as it stands")
  }
  let mut last = first.revision
  let next = async fn(
    what : String,
    wanted : (Array[@moonsd.Endpoint]) -> Bool,
  ) {
    let waited = @async.with_timeout_opt(settle, () => {
      for ;; {
        let update = watcher.next()
        if update.revision < last {
          fail("a watcher's revision went backwards")
        }
        last = update.revision
        if wanted(update.endpoints) {
          break
        }
      }
    })
    if waited is None {
      fail("not within \{settle} ms: " + what)
    }
  }
  let c = registrar.register(service, ep(3), ttl)
  next("a watcher hears an endpoint arrive", list => has(list, ep(3)))
  registrar.deregister(c)
  next("a watcher hears an endpoint leave", list => !has(list, ep(3)))
  registrar.deregister(a)
  next("a watcher hears the service empty", list => list.length() == 0)
  // `hold` and `View`, which any backend gets from the traits.
  @async.with_task_group(group => {
    let view = @moonsd.View::new()
    let following = group.spawn(
      () => view.follow(discovery, service),
      allow_failure=true,
    )
    let holding = group.spawn(
      () => @moonsd.hold(registrar, service, ep(4), ttl~),
      allow_failure=true,
    )
    eventually(settle, "a held endpoint reaches a view", () => {
      has(view.endpoints(), ep(4))
    })
    holding.cancel()
    eventually(settle, "an endpoint no longer held leaves the view", () => {
      !has(view.endpoints(), ep(4))
    })
    following.cancel()
  })
  // A lease nobody renews ends by itself.
  if expiry {
    registrar.register(service, ep(5), short_ttl) |> ignore
    eventually(settle + short_ttl, "a lease not renewed ends", () => {
      !has(discovery.resolve(service), ep(5))
    })
  }
}
