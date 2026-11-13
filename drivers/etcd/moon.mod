name = "moonbitstack/moonetcd"

version = "0.1.4"

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
  "moonbitstack/moonjson@0.5.0",
  "moonbitstack/moonsd@0.1.2",
  "moonbitstack/moonrpc@0.22.0",
  "moonbitstack/moonhttp@0.16.0",
  "moonbitstack/moonnet@0.1.12",
  "moonbitstack/moonbase@0.5.0",
  "moonbitstack/mooncred@0.7.0",
  "moonbitstack/moontls@0.9.17",
  "moonbitlang/async@0.22.5",
}

source = "src"
