name = "moonbitstack/moonconsul"

version = "0.1.4"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonsd"

license = "Apache-2.0"

keywords = [
  "consul",
  "service-discovery",
  "discovery",
  "service-registry",
  "health-check",
  "catalog",
  "kv",
  "key-value",
  "acl",
  "session",
  "lock",
  "distributed-lock",
  "semaphore",
  "watch",
  "blocking-query",
  "prepared-query",
  "connect",
  "service-mesh",
  "mtls",
  "spiffe",
  "intention",
  "intentions",
  "certificate",
  "auth-method",
  "binding-rule",
  "jwt",
  "client",
  "moonbit",
]

description = "A complete Consul client for MoonBit: agent, catalog, health, KV (with CAS, locks and semaphores), sessions, events, ACL (with auth-method logins), status, coordinate, prepared queries, config entries and Connect (CA certificates, authorization and intentions), with blocking queries and watch."

source = "src"

import {
  "moonbitstack/moonjson@0.5.0",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonfetch@0.1.8",
  "moonbitstack/moonsd@0.1.2",
  "moonbitstack/mooncrypt@0.5.0",
}
