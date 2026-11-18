name = "moonbitstack/moonetcd"

version = "0.2.1"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonsd"

license = "Apache-2.0"

keywords = [
  "etcd",
  "etcdv3",
  "client",
  "grpc",
  "grpc-gateway",
  "gateway",
  "http",
  "json",
  "rest",
  "kv",
  "key-value",
  "watch",
  "lease",
  "lock",
  "distributed-lock",
  "election",
  "leader-election",
  "transaction",
  "service-discovery",
  "tls",
  "ssl",
  "https",
  "mtls",
  "mutual-tls",
  "certificate",
  "x509",
  "ca",
  "alpn",
  "sni",
  "server-name",
  "secure",
  "moonbit",
]

description = "An etcd v3 client for MoonBit."

import {
  "moonbitstack/moonjson@0.5.1",
  "moonbitstack/moonsd@0.2.1",
  "moonbitstack/moonrpc@0.22.3",
  "moonbitstack/moonhttp@0.16.1",
  "moonbitstack/moonnet@0.2.2",
  "moonbitstack/moonbase@0.5.1",
  "moonbitstack/mooncred@0.8.1",
  "moonbitstack/moontls@0.10.2",
  "moonbitlang/async@0.22.5",
}

source = "src"
