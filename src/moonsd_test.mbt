// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "an endpoint's id is its address unless given" {
  let e = @moonsd.Endpoint::new("10.0.0.1", 9090)
  assert_eq(e.id, "10.0.0.1:9090")
  assert_eq(e.weight, 1)
  assert_eq(@moonsd.Endpoint::new("10.0.0.1", 9090, id="a").id, "a")
}

///|
test "an address reads back, an IPv6 host in brackets" {
  assert_eq(@moonsd.Endpoint::new("::1", 80).address(), "[::1]:80")
  for text in ["10.0.0.1:9090", "[::1]:80", "svc.local:12000"] {
    assert_eq(@moonsd.Endpoint::parse(text).address(), text)
  }
  assert_eq(@moonsd.Endpoint::parse("[::1]:80").host, "::1")
  for bad in ["", "host", ":80", "host:", "host:port", "host:70000", "host:-1"] {
    let refused = try @moonsd.Endpoint::parse(bad) catch {
      Malformed(_) => true
      _ => false
    } noraise {
      _ => false
    }
    assert_true(refused)
  }
}

///|
test "an update survives JSON" {
  let update : @moonsd.Update = {
    endpoints: [
      @moonsd.Endpoint::new(
        "10.0.0.1",
        9090,
        weight=3,
        metadata=Map([("zone", "a")]),
      ),
    ],
    revision: 7L,
  }
  let back : @moonsd.Update = @json.from_json(update.to_json())
  assert_eq(back, update)
}

///|
/// A registrar that does what the test says, and writes down what was asked of it.
struct Scripted {
  log : Array[String]
  // What each renew does, in turn; after the last, it succeeds.
  renewals : Array[Error]
  // What each register after the first does, in turn; after the last, it succeeds.
  registers : Array[Error]
  // What the first register does, when it should not succeed.
  first : Error?
  mut count : Int32
}

///|
fn Scripted::new(
  renewals~ : Array[Error] = [],
  registers~ : Array[Error] = [],
  first? : Error,
) -> Scripted {
  { log: [], renewals, registers, first, count: 0, }
}

///|
impl @moonsd.Registrar for Scripted with fn register(
  self,
  service,
  endpoint,
  ttl,
) {
  self.log.push("register")
  self.count = self.count + 1
  if self.count == 1 && self.first is Some(e) {
    raise e
  }
  if self.count > 1 && self.registers.length() > 0 {
    raise self.registers.remove(0)
  }
  { service, endpoint, ttl, token: self.count.to_string(), }
}

///|
impl @moonsd.Registrar for Scripted with fn renew(self, _lease) {
  self.log.push("renew")
  if self.renewals.length() > 0 {
    raise self.renewals.remove(0)
  }
}

///|
impl @moonsd.Registrar for Scripted with fn deregister(self, lease) {
  self.log.push("deregister " + lease.token)
}

///|
fn lease() -> @moonsd.Lease {
  {
    service: "s",
    endpoint: @moonsd.Endpoint::new("h", 1),
    ttl: 30,
    token: "old",
  }
}

///|
async fn run_hold(
  registrar : Scripted,
  ms~ : Int32,
  errors~ : Array[String] = [],
) -> Unit {
  @async.with_task_group(group => {
    let task = group.spawn(
      () => {
        @moonsd.hold(registrar, "s", @moonsd.Endpoint::new("h", 1), ttl=30, report=e => {
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
async test "hold renews at a third of the ttl and deregisters on the way out" {
  let registrar = Scripted::new()
  run_hold(registrar, ms=75)
  assert_eq(registrar.log[0], "register")
  assert_true(registrar.log.filter(x => x == "renew").length() >= 1)
  assert_eq(registrar.log[registrar.log.length() - 1], "deregister 1")
}

///|
async test "hold registers again when a lease has expired, and does not call it an error" {
  let registrar = Scripted::new(renewals=[@moonsd.Expired(lease())])
  let errors = []
  run_hold(registrar, ms=75, errors~)
  assert_eq(registrar.log[:3].to_owned(), ["register", "renew", "register"])
  assert_eq(errors, [])
  assert_eq(registrar.log[registrar.log.length() - 1], "deregister 2")
}

///|
async test "hold rides out a backend that is down, and comes back with it" {
  let down : Error = Failure("down")
  let registrar = Scripted::new(renewals=[down], registers=[down, down])
  let errors = []
  run_hold(registrar, ms=120, errors~)
  assert_eq(errors.length(), 3)
  assert_eq(registrar.log[registrar.log.length() - 1], "deregister 4")
}

///|
async test "hold raises when the first registration fails" {
  let registrar = Scripted::new(first=Failure("no backend"))
  let refused = try {
    @moonsd.hold(registrar, "s", @moonsd.Endpoint::new("h", 1))
    false
  } catch {
    _ => true
  }
  assert_true(refused)
  assert_eq(registrar.log, ["register"])
}

///|
/// A discovery whose watchers give what the test says, then fail.
struct Stepped {
  rounds : Array[Array[Int64]]
  mut watches : Int32
}

///|
struct Steps {
  left : Array[Int64]
}

///|
impl @moonsd.Watcher for Steps with fn next(self) {
  if self.left.length() == 0 {
    fail("the watcher broke")
  }
  let revision = self.left.remove(0)
  { endpoints: [@moonsd.Endpoint::new("h", revision.to_int())], revision, }
}

///|
impl @moonsd.Watcher for Steps with fn close(_self) {

}

///|
impl @moonsd.Discovery for Stepped with fn resolve(_self, _service) {
  []
}

///|
impl @moonsd.Discovery for Stepped with fn watch(self, _service) {
  self.watches = self.watches + 1
  if self.rounds.length() == 0 {
    fail("the backend is down")
  }
  ({ left: self.rounds.remove(0), } : Steps)
}

///|
async test "a view keeps what it heard when a watcher breaks, and watches again" {
  let discovery : Stepped = { rounds: [[1L, 2L], [5L]], watches: 0, }
  let view = @moonsd.View::new()
  assert_eq(view.endpoints().length(), 0)
  assert_eq(view.revision(), 0L)
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
    @async.sleep(5)
    assert_eq(view.revision(), 2L)
    @async.sleep(100)
    task.cancel()
  })
  assert_eq(view.revision(), 5L)
  assert_eq(view.endpoints()[0].port, 5)
  assert_true(discovery.watches >= 3)
  assert_true(errors.length() >= 2)
}
