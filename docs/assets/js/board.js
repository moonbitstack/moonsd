// The board, driven by the library compiled for this page: the registry, `hold`,
// the views and the sweeper all live in engine/moonsd.js. This file only asks and
// draws.
//
// A row is created once and then updated in place. Nothing is re-inserted while the
// board is steady, because moving a node restarts its entry animation and a board
// that replays its entry every poll reads as a fault rather than as a change. The
// same goes for the event log: lines are appended and dropped one at a time.

import * as engine from "../../engine/moonsd.js";

const board = document.querySelector("[data-board]");
const rows = board.querySelector("[data-rows]");
const rev = board.querySelector("[data-rev]");
const lamp = board.querySelector("[data-lamp]");
const ttlOut = board.querySelector("[data-ttl]");
const scale = board.querySelector("[data-scale]");
const log = document.querySelector("[data-log]");
const controls = document.querySelector("[data-controls]");

// id -> { el, parts, last } so a poll writes only what changed.
const nodes = new Map();
let shownEvents = [];
let tick = 0;

const POLL = 180;
const LOG_LINES = 9;

function rowNode(id) {
  const el = document.createElement("div");
  el.className = "row";
  el.dataset.id = id;
  el.dataset.enter = "true";
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
  // the entry is a welcome, not a loop: once it has played the row is ordinary.
  // The timer is the fallback for a page whose animations are turned off.
  const settle = () => delete el.dataset.enter;
  el.addEventListener("animationend", settle, { once: true });
  setTimeout(settle, 420);
  return el;
}

function entry(id) {
  let one = nodes.get(id);
  if (one) return one;
  const el = rowNode(id);
  one = {
    el,
    svc: el.querySelector(".svc"),
    addr: el.querySelector(".addr"),
    w: el.querySelector(".w"),
    zone: el.querySelector(".zone"),
    mode: el.querySelector(".mode"),
    bar: el.querySelector(".bar i"),
    last: {},
  };
  nodes.set(id, one);
  return one;
}

function put(el, key, value) {
  if (el.dataset[key] !== value) el.dataset[key] = value;
}

function text(el, value) {
  if (el.textContent !== value) el.textContent = value;
}

function draw(state) {
  text(rev, String(state.revision));
  text(ttlOut, (state.ttl / 1000).toFixed(1));
  put(lamp, "quiet", state.views.every((v) => v.count === 0) ? "true" : "false");

  const wanted = [...state.rows].sort((a, b) =>
    a.service === b.service ? a.address.localeCompare(b.address) : a.service.localeCompare(b.service)
  );

  for (const row of wanted) {
    const node = entry(row.id);
    put(node.el, "live", row.live ? "true" : "false");
    put(node.el, "mode", row.mode);
    text(node.svc, row.service);
    text(node.addr, row.address);
    text(node.w, "×" + row.weight);
    text(node.zone, row.zone);
    text(node.mode, row.mode === "manual" ? "lease" : "hold");
    let width = row.live ? 1 : 0;
    if (row.mode === "manual" && row.live) {
      width = Math.max(0, Math.min(1, row.left / state.ttl));
    }
    const scaled = "scaleX(" + width.toFixed(4) + ")";
    if (node.last.bar !== scaled) {
      node.last.bar = scaled;
      node.bar.style.transform = scaled;
    }
    const shade = row.mode === "manual" ? "0.95" : "0.45";
    if (node.last.shade !== shade) {
      node.last.shade = shade;
      node.bar.style.opacity = shade;
    }
  }

  // Rows that are gone leave at once. The survivors are re-ordered only when the
  // order or the membership actually changed, which is when something happened.
  for (const [id, node] of nodes) {
    if (!wanted.some((r) => r.id === id)) {
      node.el.remove();
      nodes.delete(id);
    }
  }
  const order = [...rows.children].map((el) => el.dataset.id).join("|");
  const target = wanted.map((r) => r.id).join("|");
  if (order !== target) {
    for (const row of wanted) rows.append(nodes.get(row.id).el);
  }

  if (scale) {
    text(scale, state.views.map((v) => v.service + " " + v.count).join(" · "));
  }
  drawLog(state.events);
}

function drawLog(events) {
  if (!log) return;
  const tail = events.slice(-LOG_LINES);
  if (tail.join("\u0000") === shownEvents.join("\u0000")) return;

  // Drop the lines that left the window, then append the ones that arrived: the log
  // grows a line at a time, and a reader watching it never sees it start over.
  let drop = 0;
  while (drop < shownEvents.length && !tail.includes(shownEvents[drop])) drop += 1;
  for (let i = 0; i < drop; i += 1) {
    if (log.firstElementChild) log.firstElementChild.remove();
  }
  shownEvents = shownEvents.slice(drop);

  if (tail.slice(0, shownEvents.length).join("\u0000") !== shownEvents.join("\u0000")) {
    // the registry rewrote its history rather than appending to it
    log.replaceChildren();
    shownEvents = [];
  }

  for (const line of tail.slice(shownEvents.length)) {
    const one = document.createElement("div");
    const stamp = document.createElement("span");
    stamp.className = "t";
    tick += 1;
    stamp.textContent = String(tick).padStart(3, "0");
    one.append(stamp, document.createTextNode(line));
    log.append(one);
    shownEvents.push(line);
  }
  log.scrollTop = log.scrollHeight;
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
      // the whole board is about to be replaced; let the new rows arrive cleanly
      for (const node of nodes.values()) node.el.remove();
      nodes.clear();
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
