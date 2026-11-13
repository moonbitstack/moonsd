// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
priv struct Held {
  endpoint : @moonsd.Endpoint
  token : String
  mut expires : Int64?
}

///|
/// A registry in this process: for tests, for a single-process deployment, and as the worked
/// example of the contract.
///
/// With a `now` clock a lease ends `ttl` milliseconds after its last renewal, noticed by the next
/// call that looks and by `sweep`; without one nothing expires, because this package reads no
/// clock of its own.
pub struct Registry {
  priv services : Map[String, Map[String, Held]]
  priv followers : Map[String, Array[Follower]]
  priv now : (() -> Int64)?
  priv mut revision : Int64
  priv mut seq : Int64
}

///|
pub fn Registry::new(now? : () -> Int64) -> Registry {
  { services: Map([]), followers: Map([]), now, revision: 0L, seq: 0L, }
}

///|
fn Registry::update(self : Registry, service : String) -> @moonsd.Update {
  let endpoints = match self.services.get(service) {
    Some(held) => held.values().map(h => h.endpoint).collect()
    None => []
  }
  { endpoints, revision: self.revision, }
}

///|
/// A service changed: number the change and tell whoever follows it.
fn Registry::changed(self : Registry, service : String) -> Unit {
  self.revision = self.revision + 1L
  let update = self.update(service)
  if self.followers.get(service) is Some(list) {
    for one in list {
      ignore(one.queue.try_put(update)) catch {
        _ => ()
      }
    }
  }
}

///|
/// Drop every lease past its time.
pub fn Registry::sweep(self : Registry) -> Unit {
  guard self.now is Some(clock) else { return }
  let now = clock()
  for service, held in self.services {
    let gone = held
      .iter()
      .filter(kv => kv.1.expires is Some(at) && at <= now)
      .map(kv => kv.0)
      .collect()
    for id in gone {
      held.remove(id)
    }
    if gone.length() > 0 {
      self.changed(service)
    }
  }
}

///|
/// The services that have an endpoint.
pub fn Registry::services(self : Registry) -> Array[String] {
  self.services.iter().filter(kv => kv.1.length() > 0).map(kv => kv.0).collect()
}

///|
/// The revision, which grows with every change.
pub fn Registry::revision(self : Registry) -> Int64 {
  self.revision
}

///|
/// Everything registered, as text `restore` reads.
///
/// The revision goes out as the digits it holds rather than as a double, so a register that
/// has numbered more changes than a double carries still comes back with the number it had.
pub fn Registry::snapshot(self : Registry) -> String {
  let services : Map[String, Array[@moonsd.Endpoint]] = Map([])
  for name in self.services() {
    services[name] = self.update(name).endpoints
  }
  let revision = self.revision
  let doc : Json = {
    "revision": Json::number(revision.to_double(), repr=revision.to_string()),
    "services": Json(services),
  }
  @moonjson.dumps(doc)
}

///|
/// A registry holding what `snapshot` wrote. Restored entries have no lease to renew and do not
/// expire: whoever registered them registers again.
pub fn Registry::restore(
  text : StringView,
  now? : () -> Int64,
) -> Registry raise @moonsd.Refused {
  let doc = @moonjson.loads(text, @moonjson.strict) catch {
    e => raise Malformed("not a snapshot: " + e.message())
  }
  guard doc is Object(fields) else { raise Malformed("not a snapshot") }
  let revision = match fields.get("revision") {
    Some(Number(_, repr=Some(digits))) =>
      @string.parse_int64(digits[:]) catch {
        _ =>
          raise Malformed("not a snapshot: the revision is not a whole number")
      }
    Some(Number(value, repr=None)) => value.to_int64()
    _ => raise Malformed("not a snapshot")
  }
  guard fields.get("services") is Some(listed) else {
    raise Malformed("not a snapshot")
  }
  let services : Map[String, Array[@moonsd.Endpoint]] = @json.from_json(listed) catch {
    e => raise Malformed("not a snapshot: \{e}")
  }
  let out = Registry::new(now?)
  out.revision = revision
  for name, endpoints in services {
    let held : Map[String, Held] = Map([])
    for endpoint in endpoints {
      held[endpoint.id] = { endpoint, token: "restored", expires: None, }
    }
    out.services[name] = held
  }
  out
}

///|
fn Registry::deadline(self : Registry, ttl : Int32) -> Int64? {
  self.now.map(clock => clock() + ttl.to_int64())
}

///|
pub impl @moonsd.Registrar for Registry with fn register(
  self,
  service,
  endpoint,
  ttl,
) {
  self.sweep()
  self.seq = self.seq + 1L
  let token = self.seq.to_string()
  let held = match self.services.get(service) {
    Some(held) => held
    None => {
      let held = Map([])
      self.services[service] = held
      held
    }
  }
  held[endpoint.id] = { endpoint, token, expires: self.deadline(ttl), }
  self.changed(service)
  { service, endpoint, ttl, token, }
}

///|
pub impl @moonsd.Registrar for Registry with fn renew(self, lease) {
  self.sweep()
  match self.services.get(lease.service) {
    Some(list) if list.get(lease.endpoint.id) is Some(held) &&
      held.token == lease.token => held.expires = self.deadline(lease.ttl)
    _ => raise @moonsd.Refused::Expired(lease)
  }
}

///|
pub impl @moonsd.Registrar for Registry with fn deregister(self, lease) {
  if self.services.get(lease.service) is Some(list) &&
    list.get(lease.endpoint.id) is Some(held) &&
    held.token == lease.token {
    list.remove(lease.endpoint.id)
    self.changed(lease.service)
  }
}

///|
pub impl @moonsd.Discovery for Registry with fn resolve(self, service) {
  self.sweep()
  self.update(service).endpoints
}

///|
pub impl @moonsd.Discovery for Registry with fn watch(self, service) {
  self.sweep()
  let follower : Follower = {
    registry: self,
    service,
    queue: @aqueue.Queue::Queue(kind=Unbounded),
  }
  ignore(follower.queue.try_put(self.update(service)))
  match self.followers.get(service) {
    Some(list) => list.push(follower)
    None => self.followers[service] = [follower]
  }
  follower
}

///|
pub extend Registry with @moonsd.Registrar::{register, renew, deregister}

///|
pub extend Registry with @moonsd.Discovery::{resolve, watch}

///|
priv struct Follower {
  registry : Registry
  service : String
  queue : @aqueue.Queue[@moonsd.Update]
}

///|
impl @moonsd.Watcher for Follower with fn next(self) {
  self.queue.get()
}

///|
impl @moonsd.Watcher for Follower with fn close(self) {
  if self.registry.followers.get(self.service) is Some(list) {
    self.registry.followers[self.service] = list.filter(one => {
      !physical_equal(one, self)
    })
  }
  self.queue.close()
}
