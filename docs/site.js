/* ==========================================================================
   Programme — site behaviour

   Four things only: the navigation background, the entrances that belong to
   the scorebook idea, the match clock, and the statistics demonstration.

   Everything here is an enhancement. With this file blocked the page is
   complete: nothing is hidden, the clock holds its printed time, and the
   statistics section shows the event and its derived values.
   ========================================================================== */

(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  var nav = document.getElementById("nav");
  var ticking = false;

  /* ------------------------------------------------------------------ */
  /* Entrances                                                           */
  /*                                                                     */
  /* Driven by position rather than by intersection events, so jumping    */
  /* straight to an anchor still leaves everything above it visible.      */
  /* ------------------------------------------------------------------ */

  var pending = Array.prototype.slice.call(
    document.querySelectorAll("#hero-sheet, #spread, #docs, #derive, .pitch-bleed, .coverage")
  );

  function enter(element) {
    var opens = element.id === "hero-sheet" || element.id === "spread";
    element.classList.add(opens ? "is-open" : "is-in");
    if (element.id === "derive") startDeriveDemo();
  }

  function sweep() {
    for (var i = pending.length - 1; i >= 0; i--) {
      var element = pending[i];
      if (element.getBoundingClientRect().top < window.innerHeight * 0.9) {
        enter(element);
        pending.splice(i, 1);
      }
    }
  }

  function frame() {
    if (nav) nav.classList.toggle("is-stuck", (window.scrollY || window.pageYOffset) > 8);
    sweep();
    ticking = false;
  }

  function onScroll() {
    if (ticking) return;
    ticking = true;
    window.requestAnimationFrame(frame);
  }

  window.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("resize", onScroll, { passive: true });

  /* ------------------------------------------------------------------ */
  /* Statistics: removing the event and putting it back                  */
  /* ------------------------------------------------------------------ */

  var derive = document.getElementById("derive");
  var toggle = document.getElementById("derive-toggle");
  var state = document.getElementById("derive-state");
  var demoPlayed = false;

  function setRemoved(isRemoved) {
    if (!derive) return;
    derive.classList.toggle("is-removed", isRemoved);
    if (state) state.textContent = isRemoved ? "Without this event" : "Including this event";
    if (toggle) {
      toggle.textContent = isRemoved
        ? toggle.getAttribute("data-restore")
        : toggle.getAttribute("data-remove");
    }
  }

  function startDeriveDemo() {
    if (demoPlayed || reduceMotion.matches) return;
    demoPlayed = true;
    window.setTimeout(function () {
      setRemoved(true);
      window.setTimeout(function () {
        setRemoved(false);
      }, 2200);
    }, 1000);
  }

  if (toggle) {
    toggle.addEventListener("click", function () {
      demoPlayed = true;
      setRemoved(!derive.classList.contains("is-removed"));
    });
  }

  /* ------------------------------------------------------------------ */
  /* The match clock                                                     */
  /* ------------------------------------------------------------------ */

  /* High-school rules count down inside the period, which is what the app
     displays and what the screenshot in the hero shows. */
  var clock = document.getElementById("live-clock");

  if (clock && !reduceMotion.matches) {
    var remaining = 16 * 60 + 13;
    var timer = window.setInterval(function () {
      if (remaining <= 0) {
        window.clearInterval(timer);
        return;
      }
      remaining -= 1;
      clock.textContent = Math.floor(remaining / 60) + ":" + ("0" + (remaining % 60)).slice(-2);
    }, 1000);
  }

  /* Wait a frame so the entrances actually animate on first paint. */
  window.requestAnimationFrame(function () {
    window.requestAnimationFrame(frame);
  });
})();
