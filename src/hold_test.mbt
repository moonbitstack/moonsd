// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The behaviour of `hold` and `View` that the contract promises but a backend can
// still get wrong: how often a lease is renewed, what is reported when the backend
// cannot be told the endpoint is leaving, and whose word a view takes after a
// watcher has been restarted.

///|
/// A registrar that accepts everything, and may refuse to hear that an endpoint is
/// leaving.
struct Grumpy {
  hears : Bool
  mut renewals : Int32
  at : Array[Int64]
}

///|
impl @moonsd.Registrar for Grumpy with fn register(
  _self,
  service,
  endpoint,
  ttl,
) {
  { service, endpoint, ttl, token: endpoint.id, }
}

///|
impl @moonsd.Registrar for Grumpy with fn renew(self, _lease) {
  self.renewals = self.renewals + 1
  self.at.push(@async.now())
}

///|
impl @moonsd.Registrar for Grumpy with fn deregister(self, lease) {
  if !self.hears {
    raise @moonsd.Refused::Malformed("no part of " + lease.service + " is here")
  }
}

///|
async fn run_generic(
  registrar : &@moonsd.Registrar,
  ms~ : Int32,
  ttl~ : Int32,
  errors~ : Array[String],
) -> Unit {
  @async.with_task_group(group => {
    let task = group.spawn(
      () => {
        @moonsd.hold(registrar, "s", @moonsd.Endpoint::new("h", 1), ttl~, report=e => {
          errors.push(e.to_string())
        })
      },
      allow_failure=true,
    )
    @async.sleep(ms)
    task.cancel()
  })
}

///|
async test "a backend that refuses the deregistration hears about it" {
  let registrar : Grumpy = { hears: false, renewals: 0, at: [], }
  let errors = []
  run_generic(registrar, ms=100, ttl=90, errors~)
  assert_true(errors.length() == 1)
  assert_true(errors[0].contains("no part of s is here"))
}

///|
test "a lease is renewed at a third of its life, and never at zero" {
  assert_eq(@moonsd.renew_after(30), 10)
  assert_eq(@moonsd.renew_after(9_000), 3_000)
  assert_eq(@moonsd.renew_after(1_000), 333)
  assert_eq(@moonsd.renew_after(3), 1)
  assert_eq(@moonsd.renew_after(2), 1)
  assert_eq(@moonsd.renew_after(0), 1)
}

///|
async test "a hold renews before its lease would end" {
  let registrar : Grumpy = { hears: true, renewals: 0, at: [], }
  let errors = []
  // One renewal has to happen inside the first lease, or the endpoint would be
  // dropped by its own registry between renewals. A third of a 1.2 s lease leaves
  // room for a slow machine; timing more precisely than that is not this test's job.
  run_generic(registrar, ms=1_100, ttl=1_200, errors~)
  assert_true(registrar.at.length() >= 1)
  assert_eq(errors.length(), 0)
}

///|
/// A watcher that gives what it is told, then breaks, the way a backend restarting
/// does; the next watcher starts again from whatever the backend now believes.
struct Rounds {
  left : Array[Int64]
}

///|
impl @moonsd.Watcher for Rounds with fn next(self) {
  if self.left.length() == 0 {
    fail("the watcher broke")
  }
  let revision = self.left.remove(0)
  { endpoints: [@moonsd.Endpoint::new("h", revision.to_int())], revision, }
}

///|
impl @moonsd.Watcher for Rounds with fn close(_self) {

}

///|
impl @moonsd.Discovery for Restarting with fn resolve(_self, _service) {
  []
}

///|
impl @moonsd.Discovery for Restarting with fn watch(self, _service) {
  guard self.rounds.length() > 0 else { fail("the backend is down") }
  ({ left: self.rounds.remove(0), } : Rounds)
}

///|
struct Restarting {
  rounds : Array[Array[Int64]]
}

///|
async test "a view takes the word of a restarted watcher, even when it is older" {
  // The second watcher starts from a revision the first had already passed: after a
  // compaction a backend may number its snapshots from where it now stands, and the
  // snapshot is what the caller asked for.
  let discovery : Restarting = { rounds: [[4L], [2L]], }
  let view = @moonsd.View::new()
  let errors = []
  @async.with_task_group(group => {
    let task = group.spawn(
      () => {
        view.follow(discovery, "s", retry=10, report=e => {
          errors.push(e.to_string())
        })
      },
      allow_failure=true,
    )
    // Wait for the second watcher's word rather than for a fixed number of
    // milliseconds: a busy machine may take a while to get to it.
    for _ in 0..<50 {
      if view.revision() == 2L {
        break
      }
      @async.sleep(20)
    }
    task.cancel()
  })
  assert_eq(view.revision(), 2L)
  assert_eq(view.endpoints()[0].port, 2)
  assert_true(errors.length() >= 1)
}
