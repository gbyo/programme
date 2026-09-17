/* Programme — restrained progressive enhancement. */

(function () {
  "use strict";

  var nav = document.getElementById("nav");
  var pending = Array.prototype.slice.call(document.querySelectorAll(".reveal"));
  var ticking = false;

  function frame() {
    if (nav) {
      nav.classList.toggle("is-stuck", (window.scrollY || window.pageYOffset) > 8);
    }

    for (var i = pending.length - 1; i >= 0; i--) {
      if (pending[i].getBoundingClientRect().top < window.innerHeight * 0.9) {
        pending[i].classList.add("is-in");
        pending.splice(i, 1);
      }
    }

    ticking = false;
  }

  function scheduleFrame() {
    if (ticking) return;
    ticking = true;
    window.requestAnimationFrame(frame);
  }

  window.addEventListener("scroll", scheduleFrame, { passive: true });
  window.addEventListener("resize", scheduleFrame, { passive: true });

  window.requestAnimationFrame(function () {
    window.requestAnimationFrame(frame);
  });
})();
