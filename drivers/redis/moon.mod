name = "moonbitstack/moonredis"

version = "0.1.6"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonsd"

license = "Apache-2.0"

keywords = [
  "redis",
  "client",
  "resp",
  "resp2",
  "resp3",
  "pipeline",
  "transaction",
  "pubsub",
  "pub-sub",
  "cluster",
  "redis-cluster",
  "sentinel",
  "cache",
  "key-value",
  "service-discovery",
  "json",
  "jsonpath",
  "redisjson",
  "redisearch",
  "full-text-search",
  "vector-search",
  "knn",
  "timeseries",
  "bloom-filter",
  "cuckoo-filter",
  "count-min-sketch",
  "top-k",
  "t-digest",
  "moonbit",
]

description = "A Redis client for MoonBit: RESP2 and RESP3, pipelines, transactions, pub/sub, cluster and sentinel."

source = "src"

import {
  "moonbitstack/moonjson@0.5.0",
  "moonbitstack/moonsd@0.1.2",
  "moonbitstack/moonnet@0.1.12",
  "moonbitstack/moontls@0.9.17",
  "moonbitlang/async@0.22.5",
}
