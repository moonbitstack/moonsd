// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The whole surface in one run: a service holding its registration while a caller follows it.
///
///     moon run src/examples/tour --target native
#coverage.skip
async fn main {
  let registry = @memory.Registry::new()
  let endpoint = @moonsd.Endpoint::new(
    "10.0.0.1",
    12000,
    metadata=Map([("zone", "a")]),
  )
  let view = @moonsd.View::new()
  @async.with_task_group(group => {
    let following = group.spawn(
      () => view.follow(registry, "greeter"),
      allow_failure=true,
    )
    let holding = group.spawn(
      () => @moonsd.hold(registry, "greeter", endpoint),
      allow_failure=true,
    )
    @async.sleep(50)
    let held = view.endpoints().map(e => e.address())
    println("while held: " + held.join(", "))
    println("in the registry: \{registry.resolve("greeter").length()}")
    holding.cancel()
    @async.sleep(50)
    println("after it leaves: \{view.endpoints().length()} endpoints")
    following.cancel()
  })
  println("revision \{registry.revision()}")
}
