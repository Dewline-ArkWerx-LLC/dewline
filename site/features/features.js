// Each feature scene plays once as it comes into view (features.css). Scenes already on screen when the
// page loads stay finished, and nothing is armed with Reduce Motion on or without IntersectionObserver.
(() => {
  if (matchMedia("(prefers-reduced-motion: reduce)").matches || !("IntersectionObserver" in window)) return;
  const below = [...document.querySelectorAll(".frow")].filter(
    (row) => row.querySelector(".fscene").getBoundingClientRect().top > innerHeight * 0.92,
  );
  if (!below.length) return;
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.closest(".frow").classList.add("is-on");
      io.unobserve(e.target);
    }
  }, { rootMargin: "0px 0px -12% 0px", threshold: 0.3 });
  for (const row of below) {
    row.classList.add("armed");
    io.observe(row.querySelector(".fscene"));
  }
  document.documentElement.classList.add("fx");
})();
