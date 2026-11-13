// The gRPC transport: HTTP/2 with the etcd service definitions. The transport keeps one
// connection per endpoint and sends each call to the next of them in turn, so a cluster
// carries the load and a member that has gone away costs one failed call before its
// connection is dropped. Each watch and keep-alive session opens a multiplexed channel of
// its own, so a disconnect there cannot disturb anything else and the stream can resume
// from its last revision.

///|
/// etcd over gRPC. Built by `Client::connect`.
///
/// `name` is what a certificate has to carry, and what the handshake offers as SNI: a
/// member reached by address and certified by name is dialled by its address and checked
/// against its name, at every dial including a reconnection.
pub struct GrpcTransport {
  targets : Array[(String, Int32)]
  // What every connection dials with; `None` unless the configuration enables TLS.
  tls : @tls.Client?
  name : String?
  // One live connection per endpoint, under the address it was dialled at.
  channels : Map[String, @net.Channel]
  // Which endpoint the next call goes to, so the members take turns.
  mut next : Int32
}

///|
/// Dial the endpoints. Nothing is sent until the first call, and a member that is not up
/// yet is dialled when a call first reaches it.
pub fn GrpcTransport::connect(
  targets : Array[(String, Int32)],
  tls? : @tls.Client,
  name? : String,
) -> GrpcTransport {
  { targets, tls, name, channels: Map([]), next: 0, }
}

///|
/// The `i`-th endpoint, wrapping around so a stream that has to move on reaches the
/// next member.
fn GrpcTransport::endpoint_at(
  self : GrpcTransport,
  i : Int32,
) -> (String, Int32) {
  let n = self.targets.length()
  if n == 0 {
    ("127.0.0.1", 2379)
  } else {
    self.targets[i % n]
  }
}

///|
/// The key an endpoint's connection is kept under.
fn address_of(target : (String, Int32)) -> String {
  target.0 + ":" + target.1.to_string()
}

///|
/// The connection to `target`, dialling it if this is the first call that reached it.
async fn GrpcTransport::open(
  self : GrpcTransport,
  target : (String, Int32),
) -> @net.Channel raise EtcdError {
  let address = address_of(target)
  match self.channels.get(address) {
    Some(channel) => channel
    None => {
      let channel = @net.Channel::connect(
        target.0,
        target.1,
        tls?=self.tls,
        name?=self.name,
      ) catch {
        _ => raise transport_error("dial " + address)
      }
      self.channels[address] = channel
      channel
    }
  }
}

///|
/// Let go of a connection that failed: the next call to that member dials again.
fn GrpcTransport::forget(self : GrpcTransport, address : String) -> Unit {
  match self.channels.get(address) {
    Some(channel) => {
      channel.close()
      self.channels.remove(address)
    }
    None => ()
  }
}

///|
/// The endpoint the next call goes to, and move the turn on.
fn GrpcTransport::take_turn(self : GrpcTransport) -> (String, Int32) {
  let target = self.endpoint_at(self.next)
  self.next = self.next + 1
  target
}

///|
impl Transport for GrpcTransport with fn unary(
  self : GrpcTransport,
  grpc_method : String,
  body : Bytes,
  metadata~ : Array[@header.Header],
  timeout? : Int32,
) -> Bytes raise EtcdError {
  guard self.targets.length() > 0 else {
    raise transport_error("no endpoint to call " + grpc_method)
  }
  let target = self.take_turn()
  let address = address_of(target)
  let channel = self.open(target)
  let reply = try {
    match timeout {
      Some(millis) =>
        channel.unary(grpc_method, body, metadata~, timeout_millis=millis)
      None => channel.unary(grpc_method, body, metadata~)
    }
  } catch {
    _ => {
      self.forget(address)
      raise transport_error(grpc_method)
    }
  }
  let messages = reply.ok() catch {
    @wire.StatusError(status, message) =>
      raise @moonetcd.EtcdError::of(status.code(), message)
  }
  match messages {
    [one] => one
    _ =>
      raise refused(13, "unexpected response message count from " + grpc_method)
  }
}

///|
impl Transport for GrpcTransport with fn collect(
  self : GrpcTransport,
  grpc_method : String,
  body : Bytes,
  metadata~ : Array[@header.Header],
) -> Array[Bytes] raise EtcdError {
  // A server-streaming call reads and changes nothing, so a member that cannot answer
  // costs the next member a turn rather than the caller the call.
  for _ in 0..<self.targets.length() {
    let target = self.take_turn()
    let address = address_of(target)
    let channel = self.open(target)
    let reply = channel.server_streaming(grpc_method, body, metadata~) catch {
      _ => {
        self.forget(address)
        continue
      }
    }
    let messages : Array[Bytes]? = Some(reply.ok()) catch { _ => None }
    match messages {
      Some(replies) => return replies
      None => self.forget(address)
    }
  }
  raise transport_error(grpc_method)
}

///|
impl Transport for GrpcTransport with fn watch(
  self : GrpcTransport,
  create : WatchCreateRequest,
  metadata~ : Array[@header.Header],
  group~ : @async.TaskGroup[Unit],
) -> &WatchStream raise EtcdError {
  let endpoint = self.endpoint_at(0)
  let mux = @net.MuxChannel::connect(
    endpoint.0,
    endpoint.1,
    tls?=self.tls,
    name?=self.name,
  ) catch {
    _ => raise transport_error("watch dial")
  }
  group.spawn_bg(no_wait=true, () => mux.read_pump())
  let bidi = mux.open_bidi("/etcdserverpb.Watch/Watch", metadata~)
  let stream = GrpcWatchStream::{
    transport: self,
    group,
    metadata,
    mux,
    bidi,
    create,
    last_revision: create.start_revision,
    watch_id: 0,
    endpoint: 0,
    reconnects: 0,
    closed: false,
  }
  stream.send_create()
  stream
}

///|
impl Transport for GrpcTransport with fn keep_alive(
  self : GrpcTransport,
  metadata~ : Array[@header.Header],
  group~ : @async.TaskGroup[Unit],
) -> &KeepAliveStream raise EtcdError {
  let endpoint = self.endpoint_at(0)
  let mux = @net.MuxChannel::connect(
    endpoint.0,
    endpoint.1,
    tls?=self.tls,
    name?=self.name,
  ) catch {
    _ => raise transport_error("keepalive dial")
  }
  group.spawn_bg(no_wait=true, () => mux.read_pump())
  @async.sleep(1)
  let bidi = mux.open_bidi("/etcdserverpb.Lease/LeaseKeepAlive", metadata~)
  let stream : &KeepAliveStream = GrpcKeepAliveStream::{ mux, bidi, }
  stream
}

///|
impl Transport for GrpcTransport with fn close(self : GrpcTransport) -> Unit {
  for _address, channel in self.channels {
    channel.close()
  }
  self.channels.clear()
}

///|
/// One watch over gRPC. The stream carries the create request; on a dropped connection
/// it reconnects to the next endpoint and re-issues the create just past the last event
/// it saw — the resume etcd's own client does. Closing the channel is what cancels the
/// watch on the server.
pub struct GrpcWatchStream {
  transport : GrpcTransport
  group : @async.TaskGroup[Unit]
  metadata : Array[@header.Header]
  mut mux : @net.MuxChannel
  mut bidi : @net.BidiStream
  mut create : WatchCreateRequest
  mut last_revision : Int64
  mut watch_id : Int64
  mut endpoint : Int32
  mut reconnects : Int32
  mut closed : Bool
}

///|
/// (Re)send the current create request. The `Watch` method takes a `WatchRequest`
/// whose oneof tags the create as `create_request` (field 1), so the bare
/// `WatchCreateRequest` has to be wrapped, not sent on its own.
async fn GrpcWatchStream::send_create(
  self : GrpcWatchStream,
) -> Unit raise EtcdError {
  let request = @moonetcd.WatchRequest::CreateRequest(self.create)
  self.bidi.send(request.encode()) catch {
    _ => raise transport_error("watch send create")
  }
}

///|
impl WatchStream for GrpcWatchStream with fn next(self : GrpcWatchStream) -> WatchResponse? raise EtcdError {
  for ;; {
    if self.closed {
      return None
    }
    let raw = self.bidi.recv() catch {
      _ => raise transport_error("watch recv")
    }
    match raw {
      Some(bytes) => {
        let response = WatchResponse::decode(bytes) catch {
          _ => raise refused(13, "decode WatchResponse failed")
        }
        if response.watch_id != 0 {
          self.watch_id = response.watch_id
        }
        if response.header.revision > self.last_revision {
          self.last_revision = response.header.revision
        }
        return Some(response)
      }
      None => {
        if self.reconnects >= 3 {
          self.closed = true
          return None
        }
        self.reconnects = self.reconnects + 1
        self.reconnect()
      }
    }
  }
}

///|
/// Move to the next endpoint and resume from just after the last event seen.
async fn GrpcWatchStream::reconnect(
  self : GrpcWatchStream,
) -> Unit raise EtcdError {
  self.mux.close()
  self.endpoint = self.endpoint + 1
  let address = self.transport.endpoint_at(self.endpoint)
  let mux = @net.MuxChannel::connect(
    address.0,
    address.1,
    tls?=self.transport.tls,
    name?=self.transport.name,
  ) catch {
    _ => raise transport_error("watch reconnect dial")
  }
  self.group.spawn_bg(no_wait=true, () => mux.read_pump())
  let bidi = mux.open_bidi("/etcdserverpb.Watch/Watch", metadata=self.metadata)
  self.mux = mux
  self.bidi = bidi
  let from = if self.last_revision > 0 { self.last_revision + 1 } else { 0 }
  self.create = { ..self.create, start_revision: from, }
  self.send_create()
}

///|
impl WatchStream for GrpcWatchStream with fn close(self : GrpcWatchStream) -> Unit {
  self.closed = true
  // Closing the channel ends the bidi stream, which is what cancels the watch on
  // the server; a cancel message first would need an awaited send, and the server
  // treats the stream's end the same way.
  self.mux.close()
}

///|
/// One keep-alive session over gRPC: a bidi stream on its own connection, so it never
/// disturbs the unary path.
pub struct GrpcKeepAliveStream {
  mux : @net.MuxChannel
  bidi : @net.BidiStream
}

///|
impl KeepAliveStream for GrpcKeepAliveStream with fn keep_alive(
  self : GrpcKeepAliveStream,
  id : Int64,
) -> Unit raise EtcdError {
  let request = @moonetcd.LeaseKeepAliveRequest::{ id, }
  self.bidi.send(request.encode()) catch {
    _ => raise transport_error("keepalive send")
  }
}

///|
impl KeepAliveStream for GrpcKeepAliveStream with fn next(
  self : GrpcKeepAliveStream,
) -> LeaseKeepAliveResponse? raise EtcdError {
  let raw = self.bidi.recv() catch {
    _ => raise transport_error("keepalive recv")
  }
  match raw {
    Some(bytes) =>
      Some(
        LeaseKeepAliveResponse::decode(bytes) catch {
          _ => raise refused(13, "decode KeepAliveResponse failed")
        },
      )
    None => None
  }
}

///|
impl KeepAliveStream for GrpcKeepAliveStream with fn close(
  self : GrpcKeepAliveStream,
) -> Unit {
  self.mux.close()
}
