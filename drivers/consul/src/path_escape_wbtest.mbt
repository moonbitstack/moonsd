// White-box tests for the ids this library puts in a path. A service id, a
// check id, a node name and an address are free-form strings — they hold
// spaces, slashes and colons on real agents — so each one travels as a single
// percent-encoded path segment, and these tests pin the URL each call builds.

///|
test "url_encode keeps the unreserved set and escapes the rest" {
  assert_eq(url_encode("web-1_2.3~x"), "web-1_2.3~x")
  assert_eq(url_encode("web 2"), "web%202")
  assert_eq(url_encode("a/b"), "a%2Fb")
  assert_eq(url_encode("10.0.0.1:8301"), "10.0.0.1%3A8301")
  assert_eq(url_encode("a+b"), "a%2Bb")
  assert_eq(url_encode(""), "")
}

///|
/// A name outside ASCII becomes its UTF-8 bytes, which is what the agent
/// decodes; encoding the code points one by one would lose it.
test "url_encode encodes a name outside ASCII as UTF-8 bytes" {
  assert_eq(url_encode("服务"), "%E6%9C%8D%E5%8A%A1")
  assert_eq(url_encode("café"), "caf%C3%A9")
}

///|
async test "service_deregister escapes the service id" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  let id = "moon consul/it 1"
  ignore(client.agent().service_deregister(id))
  let req = fake.last().unwrap()
  assert_eq(req.verb, "PUT")
  assert_eq(
    req.url,
    "http://127.0.0.1:8500/v1/agent/service/deregister/moon%20consul%2Fit%201",
  )
}

///|
async test "check_deregister escapes the check id" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(client.agent().check_deregister("service:web 1/2"))
  assert_eq(
    fake.last().unwrap().url,
    "http://127.0.0.1:8500/v1/agent/check/deregister/service%3Aweb%201%2F2",
  )
}

///|
async test "check_pass escapes the check id" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(client.agent().check_pass("service:web 1/2"))
  assert_eq(
    fake.last().unwrap().url,
    "http://127.0.0.1:8500/v1/agent/check/pass/service%3Aweb%201%2F2",
  )
}

///|
async test "check_fail escapes the check id" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(client.agent().check_fail("service:web 1/2"))
  assert_eq(
    fake.last().unwrap().url,
    "http://127.0.0.1:8500/v1/agent/check/fail/service%3Aweb%201%2F2",
  )
}

///|
async test "check_update escapes the check id and keeps the body" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(
    client
    .agent()
    .check_update({
      check_id: "service:web 1/2",
      status: "warning",
      output: Some("slow"),
    }),
  )
  let req = fake.last().unwrap()
  assert_eq(
    req.url,
    "http://127.0.0.1:8500/v1/agent/check/update/service%3Aweb%201%2F2",
  )
  let body = bytes_text(req.body)
  assert_eq(body.contains("\"Status\":\"warning\""), true)
}

///|
async test "join escapes the address it dials" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(client.agent().join("10.0.0.1:8301"))
  let req = fake.last().unwrap()
  assert_eq(req.url, "http://127.0.0.1:8500/v1/agent/join/10.0.0.1%3A8301")
  assert_false(req.url.contains("wan="))
}

///|
async test "join keeps the wan pair beside the escaped address" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(client.agent().join("10.0.0.1:8302", wan=true))
  assert_eq(
    fake.last().unwrap().url,
    "http://127.0.0.1:8500/v1/agent/join/10.0.0.1%3A8302?wan=1",
  )
}

///|
async test "force_leave escapes the node name" {
  let fake = FakeTransport::one(ok_response())
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(client.agent().force_leave("node one"))
  assert_eq(
    fake.last().unwrap().url,
    "http://127.0.0.1:8500/v1/agent/force-leave/node%20one",
  )
}

///|
async test "service maintenance escapes the service id" {
  let fake = FakeTransport::new([ok_response(), ok_response()])
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(client.agent().enable_service_maintenance("web/1", reason="deploy"))
  ignore(client.agent().disable_service_maintenance("web/1"))
  let seen = fake.seen()
  assert_eq(
    seen[0].url,
    "http://127.0.0.1:8500/v1/agent/service/maintenance/web%2F1?enable=true&reason=deploy",
  )
  assert_eq(
    seen[1].url,
    "http://127.0.0.1:8500/v1/agent/service/maintenance/web%2F1?enable=false",
  )
}

///|
async test "a watch of one agent service escapes its id" {
  let fake = FakeTransport::one(json_response("{\"ID\":\"web/1\"}"))
  let client = Client::with_address("127.0.0.1:8500", fake)
  ignore(client.poll(AgentService("web/1")))
  assert_eq(
    fake.last().unwrap().url,
    "http://127.0.0.1:8500/v1/agent/service/web%2F1",
  )
}
