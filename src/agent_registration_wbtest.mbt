// White-box tests for the two registration bodies. The agent decodes each one
// into a struct that refuses fields it does not know, so a body has to carry
// the names the agent declares: `ID` for a standalone check, `CheckID` for a
// check nested in a service, and the namespace only in the query.

///|
/// The body of a request, parsed, for the field-by-field assertions below.
fn body_of(req : Request) -> Json {
  @json.parse(bytes_text(req.body)) catch {
    e => abort("the body is not JSON: \{e}")
  }
}

///|
async test "check_register names the check ID, not CheckID" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(
    client
    .agent()
    .check_register({
      id: Some("check-1"),
      name: "memory",
      notes: Some("free memory"),
      service_id: Some("web-1"),
      ns: None,
      status: Some("passing"),
      definition: { ..default_service_check, ttl: Some("30s"), },
    }),
  )
  let req = fake.last().unwrap()
  assert_eq(req.url, "http://127.0.0.1:8500/v1/agent/check/register")
  assert_eq(
    body_of(req),
    Json::object(
      Map([
        ("TTL", Json::string("30s")),
        ("ID", Json::string("check-1")),
        ("Name", Json::string("memory")),
        ("Notes", Json::string("free memory")),
        ("ServiceID", Json::string("web-1")),
        ("Status", Json::string("passing")),
      ]),
    ),
  )
}

///|
/// A definition that names itself would otherwise write `CheckID`, which this
/// endpoint calls an unknown field; the registration's `ID` is the one that
/// counts.
async test "check_register drops the definition's own check id" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(
    client
    .agent()
    .check_register({
      id: Some("check-2"),
      name: "disk",
      notes: None,
      service_id: None,
      ns: None,
      status: None,
      definition: {
        ..default_service_check,
        id: Some("ignored"),
        ttl: Some("10s"),
      },
    }),
  )
  assert_eq(
    body_of(fake.last().unwrap()),
    Json::object(
      Map([
        ("TTL", Json::string("10s")),
        ("ID", Json::string("check-2")),
        ("Name", Json::string("disk")),
      ]),
    ),
  )
}

///|
/// The namespace travels in the query, where the agent reads it; a body that
/// carries it is refused on an agent without namespaces.
async test "a registration's namespace travels in the query, never the body" {
  let fake = FakeTransport::new([ok_response(), ok_response()])
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(
    client
    .agent()
    .service_register({
      ..default_service_registration,
      id: Some("web-1"),
      name: "web",
      ns: Some("team-a"),
    }),
  )
  ignore(
    client
    .agent()
    .check_register({
      id: Some("check-3"),
      name: "disk",
      notes: None,
      service_id: None,
      ns: Some("team-a"),
      status: None,
      definition: { ..default_service_check, ttl: Some("10s"), },
    }),
  )
  let seen = fake.seen()
  assert_eq(
    seen[0].url,
    "http://127.0.0.1:8500/v1/agent/service/register?ns=team-a",
  )
  assert_eq(
    seen[1].url,
    "http://127.0.0.1:8500/v1/agent/check/register?ns=team-a",
  )
  for req in seen {
    assert_false(bytes_text(req.body).contains("Namespace"))
  }
}

///|
/// The call's own namespace outranks the record's.
async test "the call's namespace beats the record's" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(
    client
    .agent()
    .service_register(
      {
        ..default_service_registration,
        id: Some("web-2"),
        name: "web",
        ns: Some("team-a"),
      },
      options={ ..default_write_options, ns: Some("team-b"), },
    ),
  )
  assert_eq(
    fake.last().unwrap().url,
    "http://127.0.0.1:8500/v1/agent/service/register?ns=team-b",
  )
}
