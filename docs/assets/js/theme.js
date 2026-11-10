// The theme twin and the page's scroll bar. The choice lives for one visit, in
// sessionStorage: a reader who reloads gets the system's answer again.

(function () {
  "use strict";
  var root = document.documentElement;
  var KEY = "moonsd-theme";

  function paint() {
    var theme = root.getAttribute("data-theme") || "light";
    var buttons = document.querySelectorAll("#theme [data-set-theme]");
    for (var i = 0; i < buttons.length; i++) {
      var on = buttons[i].getAttribute("data-set-theme") === theme;
      buttons[i].classList.toggle("on", on);
      buttons[i].setAttribute("aria-pressed", on ? "true" : "false");
    }
  }

  function apply(theme) {
    root.setAttribute("data-theme", theme);
    try { sessionStorage.setItem(KEY, theme); } catch (e) {}
    paint();
  }

  var saved = null;
  try { saved = sessionStorage.getItem(KEY); } catch (e) {}
  if (!saved) {
    saved = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark" : "light";
  }
  root.setAttribute("data-theme", saved);
  paint();

  var group = document.getElementById("theme");
  if (group) {
    group.addEventListener("click", function (event) {
      var button = event.target.closest ? event.target.closest("[data-set-theme]") : null;
      if (button) apply(button.getAttribute("data-set-theme"));
    });
  }

  // At the very top there is nothing to move toward, so the page's thumb is not
  // drawn; it keeps its width either way, so nothing shifts when it appears.
  function mark() { root.classList.toggle("at-top", window.scrollY <= 0); }
  window.addEventListener("scroll", mark, { passive: true });
  mark();
})();
