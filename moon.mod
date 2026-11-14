name = "moonbitstack/moonsd"

version = "0.2.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonsd"

license = "Apache-2.0"

keywords = [
  "service-discovery",
  "discovery",
  "registry",
  "service-registry",
  "register",
  "lease",
  "watcher",
  "endpoint",
  "microservices",
  "backend",
  "redis",
  "etcd",
  "consul",
  "conformance",
  "json",
  "snapshot",
  "restore",
  "revision",
  "in-memory",
  "async",
  "moonbit",
]

description = "Service discovery for MoonBit: the contract a registry implements, an in-process registry, a conformance suite, and clients for Redis, etcd and Consul."

import {
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonjson@0.5.0",
}

source = "src"
