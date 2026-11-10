// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// `hold` and `View` are written once, against the traits: a backend gets both by implementing
// them, and they stay in the task that wants them rather than in a thread of the backend's own.

///|
/// How long `View::follow` waits before watching again after a watcher fails, in milliseconds.
pub let retry : Int32 = 1000

///|
/// How long `hold` waits between two renewals of a lease of `ttl` milliseconds: a third, the
/// interval a lease needs to survive two lost renewals. Never zero, so a tiny `ttl` does not
/// turn the loop into a spin.
pub fn renew_after(ttl : Int32) -> Int32 {
  let third = ttl / 3
  if third < 1 {
    1
  } else {
    third
  }
}

///|
/// Keep `endpoint` registered under `service` until the task is cancelled, then remove it.
///
/// It renews every `renew_after(ttl)` milliseconds, a third of the lease. The first `register`
/// failing is raised: nothing has been announced, and the caller should hear. After that a
/// failure is a backend that went away, which is no reason to stop serving: it goes to `report`
/// and the next round registers again, so the endpoint comes back with the backend.
pub async fn hold(
  registrar : &Registrar,
  service : String,
  endpoint : Endpoint,
  ttl~ : Int32 = ttl,
  report? : (Error) -> Unit,
) -> Unit {
  let tell = report.unwrap_or(_ => ())
  let mut lease = Some(registrar.register(service, endpoint, ttl))
  defer (if lease is Some(held) {
    @async.protect_from_cancel(() => {
      registrar.deregister(held) catch {
        e => tell(e)
      }
    })
  })
  for ;; {
    @async.sleep(renew_after(ttl))
    match lease {
      Some(held) =>
        registrar.renew(held) catch {
          e if @async.is_being_cancelled() => raise e
          Expired(_) => lease = None
          e => {
            lease = None
            tell(e)
          }
        }
      None => ()
    }
    if lease is None {
      lease = Some(registrar.register(service, endpoint, ttl)) catch {
        e if @async.is_being_cancelled() => raise e
        e => {
          tell(e)
          None
        }
      }
    }
  }
}

///|
/// The latest word on a service, readable without waiting: one task runs `follow`, and the
/// request path reads `endpoints`. Choosing an endpoint must not cost a round trip.
pub struct View {
  priv mut latest : Update
}

///|
pub fn View::new() -> View {
  { latest: { endpoints: [], revision: 0L, }, }
}

///|
/// The endpoints as last heard; empty until the first update.
pub fn View::endpoints(self : View) -> Array[Endpoint] {
  self.latest.endpoints
}

///|
/// The revision of the last update, `0` until the first.
pub fn View::revision(self : View) -> Int64 {
  self.latest.revision
}

///|
/// Keep this view on `service` until the task is cancelled. When a watcher fails the view keeps
/// what it last heard, since a stale list beats none, tells `report`, and watches again after
/// `retry` milliseconds.
pub async fn View::follow(
  self : View,
  discovery : &Discovery,
  service : String,
  retry~ : Int32 = retry,
  report? : (Error) -> Unit,
) -> Unit {
  let tell = report.unwrap_or(_ => ())
  for ;; {
    follow_once(self, discovery, service) catch {
      e if @async.is_being_cancelled() => raise e
      e => tell(e)
    }
    @async.sleep(retry)
  }
}

///|
async fn follow_once(
  view : View,
  discovery : &Discovery,
  service : String,
) -> Unit {
  let watcher = discovery.watch(service)
  defer watcher.close()
  for ;; {
    view.latest = watcher.next()
  }
}
