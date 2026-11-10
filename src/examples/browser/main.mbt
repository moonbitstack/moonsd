// The page asks; the runtime here answers. Every function below is synchronous
// JavaScript-callable and only enqueues work or reads the latest view, because
// the contract is asynchronous and the page is not. One task loop owns the
// registry, one follows each service, one sweeps leases, and `state` reads what
// they left behind.

///|
/// How long a demonstration lease lasts, in milliseconds: long enough to watch a
/// bar empty, short enough to see it happen.
let lease_ms : Int32 = 8000

///|
/// How often the sweeper looks for leases whose time has run out.
let sweep_ms : Int32 = 200

///|
/// How many events the page keeps in its log.
let event_limit : Int32 = 14

///|
/// The services the board carries.
let services : Array[String] = ["greeter", "checkout"]

///|
/// One line of the board: what the page asked for, and what the registry holds.
struct Row {
  id : String
  service : String
  endpoint : @moonsd.Endpoint
  // `held` keeps itself alive with `hold`; `manual` is renewed by the page, and
  // lapses when the page stops.
  mode : String
  mut lease : @moonsd.Lease?
  mut task : @async.Task[Unit]?
  mut deadline : Int64?
}

///|
/// What the page can ask for.
enum Command {
  Add(String, @moonsd.Endpoint, String)
  Renew(String)
  Withdraw(String)
  Reset
}

///|
/// Everything the demonstration owns. The page never sees it; `state` renders it.
struct World {
  registry : @memory.Registry
  views : Map[String, @moonsd.View]
  rows : Map[String, Row]
  events : Array[String]
  inbox : @aqueue.Queue[Command]
  group : @async.TaskGroup[Unit]
  seen : Map[String, Int64]
}

///|
fn World::new(
  registry : @memory.Registry,
  group : @async.TaskGroup[Unit],
) -> World {
  let views : Map[String, @moonsd.View] = Map([])
  for service in services {
    views[service] = @moonsd.View::new()
  }
  {
    registry,
    views,
    rows: Map([]),
    events: [],
    inbox: @aqueue.Queue::Queue(kind=Unbounded),
    group,
    seen: Map([]),
  }
}

///|
/// The highest revision any watcher has reported, which is what the page shows.
fn World::revision(self : World) -> Int64 {
  let mut top = 0L
  for revision in self.seen.values() {
    if revision > top {
      top = revision
    }
  }
  top
}

///|
fn World::now() -> Int64 {
  @async.now()
}

///|
fn World::tell(self : World, line : String) -> Unit {
  self.events.push(line)
  while self.events.length() > event_limit {
    ignore(self.events.remove(0))
  }
}

///|
/// Register one instance for the demonstration and add it to the board. A `held`
/// row gets a task that runs `hold` for as long as it is on the board; a `manual`
/// row is registered once, and renewed only when the page says so.
async fn World::add(
  self : World,
  service : String,
  endpoint : @moonsd.Endpoint,
  mode : String,
) -> Unit {
  let id = "\{service}/\{endpoint.id}"
  self.rows[id] = {
    id,
    service,
    endpoint,
    mode,
    lease: None,
    task: None,
    deadline: None,
  }
  self.tell("\{mode}: \{endpoint.address()} asks to join \{service}")
  if mode == "held" {
    let task = self.group.spawn(
      () => {
        @moonsd.hold(self.registry, service, endpoint, ttl=lease_ms, report=e => {
          self.tell("hold: \{e}")
        })
      },
      allow_failure=true,
    )
    if self.rows.get(id) is Some(row) {
      row.task = Some(task)
    }
  } else {
    guard self.rows.get(id) is Some(row) else { return }
    let lease = self.registry.register(service, endpoint, lease_ms)
    row.lease = Some(lease)
    row.deadline = Some(World::now() + lease_ms.to_int64())
  }
}

///|
/// Renew a manual lease, the way a caller that is not `hold` would.
async fn World::renew(self : World, id : String) -> Unit {
  guard self.rows.get(id) is Some(row) else { return }
  match row.lease {
    Some(lease) =>
      try self.registry.renew(lease) catch {
        @moonsd.Refused::Expired(_) => {
          row.lease = None
          row.deadline = None
          self.tell("renew: \{row.endpoint.address()} was already gone")
        }
        e => self.tell("renew: \{e}")
      } noraise {
        _ => row.deadline = Some(World::now() + lease_ms.to_int64())
      }
    None => self.tell("renew: \{row.endpoint.address()} holds no lease")
  }
}

///|
/// Take a row off the board: the task carrying `hold` is cancelled, which deregisters,
/// and a manual lease is given back by hand.
async fn World::withdraw(self : World, id : String) -> Unit {
  guard self.rows.get(id) is Some(row) else { return }
  ignore(self.rows.remove(id))
  match row.task {
    Some(task) => task.cancel()
    None => ()
  }
  match row.lease {
    Some(lease) =>
      try self.registry.deregister(lease) catch {
        e => self.tell("deregister: \{e}")
      } noraise {
        _ => ()
      }
    None => ()
  }
  self.tell("withdrawn: \{row.endpoint.address()} leaves \{row.service}")
}

///|
/// Note what each watcher's revision has moved on to since the last look, so the
/// page can show the stream rather than only its latest value.
fn World::observe(self : World, service : String) -> Unit {
  guard self.views.get(service) is Some(view) else { return }
  let revision = view.revision()
  if self.seen.get(service) == Some(revision) {
    return
  }
  self.seen[service] = revision
  let addresses = view.endpoints().map(e => e.address())
  self.tell("watch \{service} · rev \{revision} · \{addresses.length()} live")
}

///|
/// Keep one view on each service for as long as the page is open.
async fn World::follow(self : World) -> Unit {
  @async.with_task_group(group => {
    for service in services {
      guard self.views.get(service) is Some(view) else { continue }
      group.spawn_bg(() => {
        view.follow(self.registry, service, report=e => {
          self.tell("follow: \{e}")
        })
      })
    }
    @async.sleep(86_400_000)
  })
}

///|
/// Notice leases whose time has run out. A registry given a clock ends them, but
/// only when something looks.
async fn World::sweep(self : World) -> Unit {
  for ;; {
    @async.sleep(sweep_ms)
    self.registry.sweep()
    for service in services {
      self.observe(service)
    }
  }
}

///|
/// Serve the page's commands, one at a time, for as long as the page is open.
async fn World::serve(self : World) -> Unit {
  for ;; {
    let command = self.inbox.get() catch { _ => return }
    match command {
      Add(service, endpoint, mode) => self.add(service, endpoint, mode)
      Renew(id) => self.renew(id)
      Withdraw(id) => self.withdraw(id)
      Reset => {
        self.clear()
        self.seed()
      }
    }
  }
}

///|
/// Take every row off the board.
async fn World::clear(self : World) -> Unit {
  let ids = self.rows.keys().collect()
  for id in ids {
    self.withdraw(id)
  }
  self.events.clear()
}

///|
/// Start the board with the fleet it opens with: two greeters, one of them kept
/// alive by `hold` and one the page renews, and a checkout kept alive by `hold`.
async fn World::seed(self : World) -> Unit {
  @async.sleep(20)
  self.add(
    "greeter",
    @moonsd.Endpoint::new(
      "10.0.0.11",
      12000,
      weight=2,
      metadata=Map([("zone", "a")]),
    ),
    "held",
  )
  self.add(
    "greeter",
    @moonsd.Endpoint::new("10.0.0.12", 12000, metadata=Map([("zone", "b")])),
    "manual",
  )
  self.add(
    "checkout",
    @moonsd.Endpoint::new("10.0.0.21", 12000, metadata=Map([("zone", "c")])),
    "held",
  )
}

///|
/// A JSON string literal for `s`.
fn quote(s : StringView) -> String {
  let out = StringBuilder()
  out.write_char('"')
  for c in s.iter() {
    match c {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      _ =>
        if c.to_int() < 0x20 {
          out.write_string("\\u00")
          out.write_string(c.to_int().to_string())
        } else {
          out.write_char(c)
        }
    }
  }
  out.write_char('"')
  out.to_string()
}

///|
/// The board as the page reads it: what each row is, how much of its lease is left,
/// and the events the watchers produced.
fn World::state(self : World) -> String {
  let out = StringBuilder()
  out.write_string("{\"ttl\":")
  out.write_string(lease_ms.to_string())
  out.write_string(",\"revision\":")
  out.write_string(self.revision().to_string())
  out.write_string(",\"rows\":[")
  let mut first = true
  for row in self.rows.values() {
    let live = self.views
      .get(row.service)
      .map(view => view.endpoints().any(e => e.id == row.endpoint.id))
      .unwrap_or(false)
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string("{\"id\":")
    out.write_string(quote(row.id))
    out.write_string(",\"service\":")
    out.write_string(quote(row.service))
    out.write_string(",\"address\":")
    out.write_string(quote(row.endpoint.address()))
    out.write_string(",\"weight\":")
    out.write_string(row.endpoint.weight.to_string())
    out.write_string(",\"zone\":")
    out.write_string(quote(row.endpoint.metadata.get("zone").unwrap_or("-")))
    out.write_string(",\"mode\":")
    out.write_string(quote(row.mode))
    out.write_string(",\"live\":")
    out.write_string(if live { "true" } else { "false" })
    out.write_string(",\"left\":")
    out.write_string(
      if row.deadline is Some(at) {
        let left = at - World::now()
        (if left > 0L { left } else { 0L }).to_string()
      } else {
        "-1"
      },
    )
    out.write_string("}")
  }
  out.write_string("],\"views\":[")
  let mut first_service = true
  for service in services {
    guard self.views.get(service) is Some(view) else { continue }
    if !first_service {
      out.write_char(',')
    }
    first_service = false
    out.write_string("{\"service\":")
    out.write_string(quote(service))
    out.write_string(",\"revision\":")
    out.write_string(view.revision().to_string())
    out.write_string(",\"count\":")
    out.write_string(view.endpoints().length().to_string())
    out.write_string(",\"addresses\":[")
    let mut first_address = true
    for endpoint in view.endpoints() {
      if !first_address {
        out.write_char(',')
      }
      first_address = false
      out.write_string(quote(endpoint.address()))
    }
    out.write_string("]}")
  }
  out.write_string("],\"events\":[")
  let mut first_event = true
  for event in self.events {
    if !first_event {
      out.write_char(',')
    }
    first_event = false
    out.write_string(quote(event))
  }
  out.write_string("]}")
  out.to_string()
}

///|
/// The world the page talks to, created once the runtime is up.
let world : Ref[World?] = Ref(None)

///|
/// Whether the loop is running and the page may talk to it.
pub fn ready() -> Bool {
  world.val is Some(_)
}

///|
/// Put an instance on the board, kept alive by `hold`.
pub fn join(
  service : String,
  host : String,
  port : Int32,
  weight : Int32,
  zone : String,
) -> Unit {
  guard world.val is Some(w) else { return }
  let endpoint = @moonsd.Endpoint::new(
    host,
    port,
    weight~,
    metadata=zones(zone),
  )
  ignore(w.inbox.try_put(Add(service, endpoint, "held"))) catch {
    _ => ()
  }
}

///|
/// Add an instance that the page must renew itself, so a lease can be watched
/// running out.
pub fn lease_manually(
  service : String,
  host : String,
  port : Int32,
  weight : Int32,
  zone : String,
) -> Unit {
  guard world.val is Some(w) else { return }
  let endpoint = @moonsd.Endpoint::new(
    host,
    port,
    weight~,
    metadata=zones(zone),
  )
  ignore(w.inbox.try_put(Add(service, endpoint, "manual"))) catch {
    _ => ()
  }
}

///|
fn zones(zone : String) -> Map[String, String] {
  if zone == "" {
    Map([])
  } else {
    Map([("zone", zone)])
  }
}

///|
/// Renew a lease the page holds.
pub fn renew(id : String) -> Unit {
  guard world.val is Some(w) else { return }
  ignore(w.inbox.try_put(Renew(id))) catch {
    _ => ()
  }
}

///|
/// Take an instance off the board.
pub fn withdraw(id : String) -> Unit {
  guard world.val is Some(w) else { return }
  ignore(w.inbox.try_put(Withdraw(id))) catch {
    _ => ()
  }
}

///|
/// Put the opening fleet back.
pub fn reset() -> Unit {
  guard world.val is Some(w) else { return }
  ignore(w.inbox.try_put(Reset)) catch {
    _ => ()
  }
}

///|
/// The board, as JSON.
pub fn state() -> String {
  guard world.val is Some(w) else {
    return "{\"ttl\":0,\"revision\":0,\"rows\":[],\"views\":[],\"events\":[]}"
  }
  w.state()
}

///|
/// The runtime: one registry on the clock of this page, a watcher for each
/// service, a sweeper, and the loop that serves the page.
async fn main {
  let registry = @memory.Registry::new(now=() => World::now())
  @async.with_task_group(group => {
    let w = World::new(registry, group)
    world.val = Some(w)
    group.spawn_bg(() => w.seed())
    group.spawn_bg(() => w.follow())
    group.spawn_bg(() => w.sweep())
    w.serve()
  })
}
