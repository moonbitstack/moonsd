// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// `check` is the suite every backend is held to, so it is held to something too: a
// backend that says it registered and answers nothing must be caught, and a backend
// whose snapshot is right but whose stream is mute must be caught as well. These use
// a short `settle` so a failure is heard quickly.

///|
/// A watcher that hands over one update at most, then never speaks again.
struct Silent {
  mut first : @moonsd.Update?
}

///|
impl @moonsd.Watcher for Silent with fn next(self) {
  match self.first {
    Some(update) => {
      self.first = None
      update
    }
    None => {
      @async.sleep(60_000)
      { endpoints: [], revision: 0L, }
    }
  }
}

///|
impl @moonsd.Watcher for Silent with fn close(_self) {

}

///|
/// A backend that accepts registrations and forgets them: `resolve` never answers.
struct Forgetting {
  kept : Array[String]
}

///|
impl @moonsd.Registrar for Forgetting with fn register(
  self,
  service,
  endpoint,
  ttl,
) {
  self.kept.push(service)
  { service, endpoint, ttl, token: endpoint.id, }
}

///|
impl @moonsd.Registrar for Forgetting with fn renew(_self, _lease) {

}

///|
impl @moonsd.Registrar for Forgetting with fn deregister(_self, _lease) {

}

///|
impl @moonsd.Discovery for Forgetting with fn resolve(_self, _service) {
  []
}

///|
impl @moonsd.Discovery for Forgetting with fn watch(_self, _service) {
  ({ first: None, } : Silent)
}

///|
async test "a backend that forgets what it registered fails the check" {
  let backend : Forgetting = { kept: [], }
  let caught = try {
    @conformance.check(backend, backend, settle=300, expiry=false)
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(caught)
  assert_eq(backend.kept, ["moonsd-conformance", "moonsd-conformance"])
}

///|
/// A registry that resolves correctly but whose watcher says nothing after the first
/// word: the snapshot is right, the stream that follows it is not.
struct Mute {
  kept : Map[String, Array[@moonsd.Endpoint]]
}

///|
impl @moonsd.Registrar for Mute with fn register(self, service, endpoint, ttl) {
  let list = self.kept.get(service).unwrap_or([])
  list.push(endpoint)
  self.kept[service] = list
  { service, endpoint, ttl, token: endpoint.id, }
}

///|
impl @moonsd.Registrar for Mute with fn renew(_self, _lease) {

}

///|
impl @moonsd.Registrar for Mute with fn deregister(self, lease) {
  match self.kept.get(lease.service) {
    Some(list) =>
      self.kept[lease.service] = list.filter(e => e.id != lease.endpoint.id)
    None => ()
  }
}

///|
impl @moonsd.Discovery for Mute with fn resolve(self, service) {
  self.kept.get(service).unwrap_or([])
}

///|
impl @moonsd.Discovery for Mute with fn watch(self, service) {
  let endpoints = @moonsd.Discovery::resolve(self, service)
  ({ first: Some({ endpoints, revision: 1L, }), } : Silent)
}

///|
async test "a backend whose watcher only speaks once fails the check" {
  let backend : Mute = { kept: Map([]), }
  let caught = try {
    @conformance.check(backend, backend, settle=300, expiry=false)
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(caught)
  assert_true(backend.kept.length() > 0)
}

///|
/// A backend whose shape is right and whose endpoints are not: it registers, renews
/// and removes correctly, but `resolve` answers with a stand-in of the same size. Only
/// a check that compares the endpoint itself catches this.
struct Drift {
  kept : Map[String, Array[@moonsd.Endpoint]]
}

///|
impl @moonsd.Registrar for Drift with fn register(self, service, endpoint, ttl) {
  let list = self.kept
    .get(service)
    .unwrap_or([])
    .filter(e => e.id != endpoint.id)
  list.push(endpoint)
  self.kept[service] = list
  { service, endpoint, ttl, token: endpoint.id, }
}

///|
impl @moonsd.Registrar for Drift with fn renew(self, lease) {
  match self.kept.get(lease.service) {
    Some(list) if list.any(e => e.id == lease.endpoint.id) => ()
    _ => raise @moonsd.Refused::Expired(lease)
  }
}

///|
impl @moonsd.Registrar for Drift with fn deregister(self, lease) {
  match self.kept.get(lease.service) {
    Some(list) =>
      self.kept[lease.service] = list.filter(e => e.id != lease.endpoint.id)
    None => ()
  }
}

///|
/// The endpoint that was registered, with the fields a caller reads changed and only the
/// id left alone: a suite that compares ids alone would call this the same endpoint.
fn elsewhere(one : @moonsd.Endpoint) -> @moonsd.Endpoint {
  @moonsd.Endpoint::new("192.0.2.1", one.port, id=one.id, weight=one.weight + 7)
}

///|
impl @moonsd.Discovery for Drift with fn resolve(self, service) {
  self.kept.get(service).unwrap_or([]).map(elsewhere)
}

///|
/// A watcher that looks again on every round, so the only thing wrong with `Drift` is
/// what its snapshots contain.
struct Polling {
  backend : Drift
  service : String
  mut revision : Int64
}

///|
impl @moonsd.Watcher for Polling with fn next(self) {
  @async.sleep(50)
  self.revision = self.revision + 1L
  {
    endpoints: @moonsd.Discovery::resolve(self.backend, self.service),
    revision: self.revision,
  }
}

///|
impl @moonsd.Watcher for Polling with fn close(_self) {

}

///|
impl @moonsd.Discovery for Drift with fn watch(self, service) {
  ({ backend: self, service, revision: 0L, } : Polling)
}

///|
async test "a backend that answers with the wrong endpoint fails the check" {
  let backend : Drift = { kept: Map([]), }
  let caught = try {
    @conformance.check(backend, backend, settle=300, expiry=false)
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(caught)
}
