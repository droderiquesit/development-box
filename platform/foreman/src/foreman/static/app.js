// Foreman front-end glue. Loaded as a file (CSP: no inline handlers, no eval).
(function () {
  "use strict";

  // Alpine (CSP build): components must be registered, not written inline.
  document.addEventListener("alpine:init", function () {
    window.Alpine.data("theme", function () {
      return {
        toggle: function () {
          var dark = document.documentElement.classList.toggle("dark");
          try { localStorage.setItem("foreman-theme", dark ? "dark" : "light"); } catch (e) {}
        },
      };
    });
    window.Alpine.data("agents", function () {
      return {
        count: "5",
        init: function () { this.count = this.$el.dataset.initial || "5"; },
      };
    });
  });

  function toast(text) {
    var box = document.getElementById("toasts");
    if (!box) return;
    var el = document.createElement("div");
    el.className = "toast";
    el.textContent = text;
    box.appendChild(el);
    setTimeout(function () { el.remove(); }, 6000);
  }

  // Surface API errors (e.g. "refusing to merge: checks are failing").
  document.addEventListener("htmx:responseError", function (evt) {
    var xhr = evt.detail.xhr;
    var msg = "Request failed (" + xhr.status + ")";
    try { msg = JSON.parse(xhr.responseText).detail || msg; } catch (e) {}
    toast(msg);
  });
  document.addEventListener("htmx:sendError", function () { toast("Network error"); });

  // Live run updates: SSE says "something changed", HTMX refetches the fragment.
  function liveRun() {
    var root = document.getElementById("run");
    if (!root || !window.EventSource) return;
    var source = new EventSource(root.dataset.stream);
    var first = true;
    source.addEventListener("update", function () {
      if (first) { first = false; return; } // page was just rendered
      if (window.htmx) window.htmx.ajax("GET", root.dataset.live, { target: "#live", swap: "innerHTML" });
    });
  }
  document.addEventListener("DOMContentLoaded", liveRun);

  if ("serviceWorker" in navigator) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("/sw.js").catch(function () {});
    });
  }
})();
