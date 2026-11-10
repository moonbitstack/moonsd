// The board, driven by the library compiled for this page: the registry, `hold`,
// the views and the sweeper all live in engine/moonsd.js. This file only asks and
// draws. A row is created once and then updated in place, so a lease bar can drain
// smoothly instead of restarting on every poll.

import * as engine from "../../engine/moonsd.js";

const board = document.querySelector("[data-board]");
const rows = board.querySelector("[data-rows]");
const rev = board.querySelector("[data-rev]");
const lamp = board.querySelector("[data-lamp]");
const ttlOut = board.querySelector("[data-ttl]");
const scale = board.querySelector("[data-scale]");
const log = document.querySelector("[data-log]");
const controls = document.querySelector("[data-controls]");

const nodes = new Map();
let lastEvents = [];
let tick = 0;

const POLL = 180;

function rowNode(id) {
  const el = document.createElement("div");
  el.className = "row";
  el.dataset.id = id;
  el.innerHTML =
    '<span class="svc"></span>' +
    '<span class="addr"></span>' +
    '<span class="dim w"></span>' +
    '<span class="dim zone"></span>' +
    '<span class="mode"></span>' +
    '<span class="bar"><i></i></span>' +
    '<span class="acts"></span>';
  const acts = el.querySelector(".acts");
  const renew = document.createElement("button");
  renew.className = "act";
  renew.type = "button";
  renew.dataset.act = "renew";
  renew.title = "renew this lease";
  renew.innerHTML =
    '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" aria-hidden="true">' +
    '<path d="M10 6a4 4 0 1 1-1.4-3.1"/><path d="M10.2 1.4v2.8H7.4"/></svg>';
  const drop = document.createElement("button");
  drop.className = "act";
  drop.type = "button";
  drop.dataset.act = "withdraw";
  drop.title = "take this instance off the board";
  drop.innerHTML =
    '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" aria-hidden="true">' +
    '<path d="M2.6 2.6l6.8 6.8M9.4 2.6l-6.8 6.8"/></svg>';
  acts.append(renew, drop);
  return el;
}

function draw(state) {
  rev.textContent = state.revision;
  ttlOut.textContent = (state.ttl / 1000).toFixed(1);
  lamp.dataset.quiet = state.views.every((v) => v.count === 0) ? "true" : "false";

  const wanted = [...state.rows].sort((a, b) =>
    a.service === b.service ? a.address.localeCompare(b.address) : a.service.localeCompare(b.service)
  );

  for (const row of wanted) {
    let node = nodes.get(row.id);
    if (!node) {
      node = rowNode(row.id);
      nodes.set(row.id, node);
      rows.append(node);
    }
    node.dataset.live = row.live ? "true" : "false";
    node.dataset.mode = row.mode;
    node.querySelector(".svc").textContent = row.service;
    node.querySelector(".addr").textContent = row.address;
    node.querySelector(".w").textContent = "×" + row.weight;
    node.querySelector(".zone").textContent = row.zone;
    node.querySelector(".mode").textContent = row.mode === "manual" ? "lease" : "hold";
    const bar = node.querySelector(".bar i");
    if (row.mode === "manual") {
      const left = Math.max(0, Math.min(1, row.left / state.ttl));
      bar.style.transform = "scaleX(" + (row.live ? left : 0) + ")";
    } else {
      bar.style.transform = "scaleX(" + (row.live ? 1 : 0) + ")";
    }
    bar.style.opacity = row.mode === "manual" ? "0.95" : "0.45";
    row.node = node;
  }

  // Rows that are gone leave at once; the survivors keep their place in this order.
  for (const [id, node] of nodes) {
    if (!wanted.some((r) => r.id === id)) {
      node.remove();
      nodes.delete(id);
    }
  }
  for (const row of wanted) rows.append(nodes.get(row.id));

  if (scale) {
    const counts = state.views.map((v) => v.service + " " + v.count).join(" · ");
    scale.textContent = counts;
  }

  if (state.events.join("\n") !== lastEvents.join("\n")) {
    lastEvents = state.events;
    if (log) {
      log.innerHTML = "";
      const tail = state.events.slice(-9);
      for (const line of tail) {
        const row = document.createElement("div");
        const stamp = document.createElement("span");
        stamp.className = "t";
        tick += 1;
        stamp.textContent = String(tick).padStart(3, "0");
        row.append(stamp, document.createTextNode(line));
        log.append(row);
      }
      log.scrollTop = log.scrollHeight;
    }
  }
}

function poll() {
  if (!engine.ready()) {
    setTimeout(poll, 80);
    return;
  }
  draw(JSON.parse(engine.state()));
  setTimeout(poll, POLL);
}

if (controls) {
  controls.addEventListener("click", (event) => {
    const button = event.target.closest("[data-do]");
    if (!button) return;
    const how = button.dataset.do;
    if (how === "join") {
      const octet = 20 + Math.floor(Math.random() * 200);
      engine.join("greeter", "10.0.0." + octet, 12000, 1, "live");
    } else if (how === "join-manual") {
      const octet = 20 + Math.floor(Math.random() * 200);
      engine.lease_manually("greeter", "10.0.0." + octet, 12000, 1, "live");
    } else if (how === "join-checkout") {
      const octet = 20 + Math.floor(Math.random() * 200);
      engine.join("checkout", "10.0.0." + octet, 12000, 1, "live");
    } else if (how === "reset") {
      engine.reset();
    }
  });
}

rows.addEventListener("click", (event) => {
  const button = event.target.closest("[data-act]");
  if (!button) return;
  const id = button.closest(".row").dataset.id;
  if (button.dataset.act === "withdraw") engine.withdraw(id);
  else engine.renew(id);
});

poll();
