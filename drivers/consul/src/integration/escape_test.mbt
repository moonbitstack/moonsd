// Ids that a path cannot carry raw, against live agents. Consul reads these
// ids back out of the decoded path, so a client that sends the id as it stands
// reaches a different resource — or none: a space ends the request line, and a
// slash splits the segment. Every call here sends an id holding both.

///|
/// A service id with a space and a slash, as a stamped name plus the suffix.
fn escaped_id(name : String) -> String {
  stamped(name) + "/one two"
}

///|
async test "agent: a service id with a space and a slash registers, reads and goes" {
  guard live() is Some(c) else { return }
  let id = escaped_id("svc-escape")
  let name = stamped("svc-escape-name")
  ignore(
    c
    .agent()
    .service_register({
      ..@moonconsul.default_service_registration,
      id: Some(id),
      name,
      port: Some(9300),
      check: Some({
        ..@moonconsul.default_service_check,
        ttl: Some("30s"),
        status: Some("passing"),
      }),
    }),
  )
  // The id came back as one entry, not two segments of a path.
  assert_eq(c.agent().services().0.contains(id), true)
  let (service, _) = c.poll(AgentService(id))
  assert_eq(service is Some(_), true)
  assert_eq(c.health().service(name, passing=true).0.length(), 1)
  // Maintenance mode and back, both keyed by the same id.
  ignore(c.agent().enable_service_maintenance(id, reason="escaped"))
  assert_eq(c.health().service(name, passing=true).0.length(), 0)
  ignore(c.agent().disable_service_maintenance(id))
  assert_eq(c.health().service(name, passing=true).0.length(), 1)
  ignore(c.agent().service_deregister(id))
  assert_eq(c.agent().services().0.contains(id), false)
  assert_eq(c.health().service(name).0.length(), 0)
}

///|
async test "agent: a check id with a space and a slash takes a pass, a fail and an update" {
  guard live() is Some(c) else { return }
  let id = escaped_id("check-escape")
  let name = stamped("check-escape-name")
  ignore(
    c
    .agent()
    .service_register({
      ..@moonconsul.default_service_registration,
      id: Some(id),
      name,
      port: Some(9301),
      check: Some({
        ..@moonconsul.default_service_check,
        ttl: Some("30s"),
        status: Some("critical"),
      }),
    }),
  )
  // A service's own check is named after its id, so it inherits the escape.
  let check_id = "service:" + id
  assert_eq(c.agent().checks().0.contains(check_id), true)
  ignore(c.agent().check_pass(check_id))
  assert_eq(c.health().service(name, passing=true).0.length(), 1)
  ignore(c.agent().check_fail(check_id))
  assert_eq(c.health().service(name, passing=true).0.length(), 0)
  ignore(
    c
    .agent()
    .check_update({
      check_id,
      status: "warning",
      output: Some("slow, but alive"),
    }),
  )
  let reported = c.agent().checks().0.get(check_id).unwrap()
  assert_eq(reported.status, Some("warning"))
  assert_eq(reported.output, Some("slow, but alive"))
  ignore(c.agent().check_pass(check_id))
  assert_eq(c.health().service(name, passing=true).0.length(), 1)
  ignore(c.agent().service_deregister(id))
  assert_eq(c.agent().checks().0.contains(check_id), false)
}

///|
async test "agent: a check registered on its own is reached by an escaped id" {
  guard live() is Some(c) else { return }
  let check_id = escaped_id("standalone-check")
  ignore(
    c
    .agent()
    .check_register({
      id: Some(check_id),
      name: "standalone",
      notes: None,
      service_id: None,
      ns: None,
      status: Some("passing"),
      definition: { ..@moonconsul.default_service_check, ttl: Some("30s"), },
    }),
  )
  assert_eq(c.agent().checks().0.contains(check_id), true)
  ignore(c.agent().check_fail(check_id))
  assert_eq(
    c.agent().checks().0.get(check_id).unwrap().status,
    Some("critical"),
  )
  ignore(c.agent().check_deregister(check_id))
  assert_eq(c.agent().checks().0.contains(check_id), false)
}

///|
async test "agent: join reaches an agent through an escaped address" {
  guard live() is Some(c) else { return }
  // The port separator is not a path character, so the address arrives as
  // `127.0.0.1%3A8301`; the agent decodes it and joins itself, which it answers
  // as a success because it is already a member.
  ignore(c.agent().join("127.0.0.1:8301"))
  assert_true(c.agent().members().0.length() >= 1)
  ignore(c.agent().join("127.0.0.1:8301", wan=true)) catch {
    // A dev agent has no WAN pool, so this may refuse; the LAN join above is
    // what proves the escape.
    _ => ()
  }
}
