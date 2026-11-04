// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The weight an endpoint carries unless it says otherwise.
pub let weight : Int32 = 1

///|
/// How long a registration lasts without being renewed, in milliseconds: go-zero's `discov`
/// default of ten seconds.
pub let ttl : Int32 = 10000

///|
/// Why a value was refused. `Malformed` is text that is not an endpoint or a snapshot;
/// `Expired` is a lease its backend no longer holds, which `hold` answers by registering again.
#derive(Eq, Debug)
pub(all) suberror Refused {
  Malformed(String)
  Expired(Lease)
}

///|
pub impl Show for Refused with fn output(self, logger) {
  match self {
    Malformed(why) => logger.write_string("malformed: " + why)
    Expired(lease) =>
      logger.write_string(
        "lease expired: " + lease.service + "/" + lease.endpoint.id,
      )
  }
}

///|
pub extend Refused with Show::{to_string, output}

///|
pub extend Refused with Eq::{equal, not_equal}

///|
pub extend Refused with Debug::{to_repr}

///|
/// One instance of a service. `id` tells it from the other instances of that service, and is
/// the address unless given. `weight` and `metadata` are carried for whoever picks among
/// endpoints; nothing here reads them.
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct Endpoint {
  id : String
  host : String
  port : Int32
  weight : Int32
  metadata : Map[String, String]
}

///|
pub extend Endpoint with Eq::{equal, not_equal}

///|
pub extend Endpoint with Debug::{to_repr}

///|
pub extend Endpoint with ToJson::{to_json}

///|
pub extend Endpoint with @json.FromJson::{from_json}

///|
pub fn Endpoint::new(
  host : String,
  port : Int32,
  id? : String,
  weight~ : Int32 = weight,
  metadata? : Map[String, String],
) -> Endpoint {
  let address = address_of(host, port)
  {
    id: id.unwrap_or(address),
    host,
    port,
    weight,
    metadata: metadata.unwrap_or(Map([])),
  }
}

///|
fn address_of(host : String, port : Int32) -> String {
  if host.contains(":") {
    "[\{host}]:\{port}"
  } else {
    "\{host}:\{port}"
  }
}

///|
/// `host:port`, with an IPv6 host in brackets, as a socket address is written.
pub fn Endpoint::address(self : Endpoint) -> String {
  address_of(self.host, self.port)
}

///|
/// An endpoint from `host:port` or `[v6]:port`.
pub fn Endpoint::parse(text : StringView) -> Endpoint raise Refused {
  guard text.rev_find(":") is Some(at) else {
    raise Malformed("no port in " + text.to_owned())
  }
  let host = text[:at].to_owned()
  let bare = if host.has_prefix("[") && host.has_suffix("]") {
    host[1:host.length() - 1].to_owned()
  } else {
    host
  }
  let port = @string.parse_int(text[at + 1:]) catch {
    _ => raise Malformed("no port in " + text.to_owned())
  }
  if bare == "" || port < 0 || port > 65535 {
    raise Malformed("not an address: " + text.to_owned())
  }
  Endpoint::new(bare, port)
}

///|
/// A registration: what `Registrar::register` hands back and takes again to renew or remove it.
/// `token` is the backend's own handle (etcd's lease id, a Consul check), opaque to everyone else.
#derive(Eq, Debug)
pub(all) struct Lease {
  service : String
  endpoint : Endpoint
  ttl : Int32
  token : String
}

///|
pub extend Lease with Eq::{equal, not_equal}

///|
pub extend Lease with Debug::{to_repr}

///|
/// A service as it stands: all its live endpoints, and a revision that grows with every change a
/// backend can number. A backend that numbers nothing counts its own updates.
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct Update {
  endpoints : Array[Endpoint]
  revision : Int64
}

///|
pub extend Update with Eq::{equal, not_equal}

///|
pub extend Update with Debug::{to_repr}

///|
pub extend Update with ToJson::{to_json}

///|
pub extend Update with @json.FromJson::{from_json}

///|
/// Where a service's instances announce themselves.
///
/// `register` makes `endpoint` known under `service` for `ttl` milliseconds; `renew` extends that,
/// and raises `Expired` once the backend has let it go; `deregister` removes it at once, and is
/// harmless on a lease already gone. Implement these three and `hold` works for the backend.
pub(open) trait Registrar {
  async fn register(Self, String, Endpoint, Int32) -> Lease
  async fn renew(Self, Lease) -> Unit
  async fn deregister(Self, Lease) -> Unit
}

///|
/// Where a service's callers find its instances.
///
/// `resolve` answers once, with no endpoints for a service nobody registered. `watch` follows one
/// service: its watcher's first `next` gives the service as it stands, and each later one waits
/// for a change. Implement these two and `View` works for the backend.
pub(open) trait Discovery {
  async fn resolve(Self, String) -> Array[Endpoint]
  async fn watch(Self, String) -> &Watcher
}

///|
/// One service followed. `next` gives whole snapshots rather than events, so losing a connection
/// costs an implementation a reconnect and a caller nothing: reconnecting, and recovering from
/// a compacted history, are the implementation's business, and what comes out is always what is
/// true now. `next` raises when the watcher cannot go on; `close` ends it.
pub(open) trait Watcher {
  async fn next(Self) -> Update
  fn close(Self) -> Unit
}
