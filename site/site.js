const copied = document.getElementById("copied");
for (const button of document.querySelectorAll("[data-copy]")) {
  const code = document.getElementById(button.dataset.copy);
  const iconOnly = button.classList.contains("icon");
  let timer;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(code.textContent);
    } catch {
      getSelection().selectAllChildren(code);
      return;
    }
    if (iconOnly) button.classList.add("is-done");
    else button.textContent = "Copied";
    copied.textContent = "Copied";
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (iconOnly) button.classList.remove("is-done");
      else button.textContent = "Copy";
      copied.textContent = "";
    }, 1600);
  });
}

// Motion that needs a script. The page is complete without any of it.
const reduce = matchMedia("(prefers-reduced-motion: reduce)");
const io = "IntersectionObserver" in window;

// Reveals for browsers without view timelines. Rects are read before the hiding class lands,
// so anything already on screen is marked in the same frame and never flashes.
if (!reduce.matches && io && !CSS.supports("animation-timeline: view()")) {
  const els = [...document.querySelectorAll(".rv")];
  const shown = els.map((el) => el.getBoundingClientRect().top < innerHeight);
  document.documentElement.classList.add("sda-fallback");
  const seen = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.classList.add("in");
      seen.unobserve(e.target);
    }
  }, { threshold: 0.15, rootMargin: "0px 0px -10% 0px" });
  els.forEach((el, i) => (shown[i] ? el.classList.add("in") : seen.observe(el)));
}

// The close's app tile blinks its cursor three times, once, when the close is mostly in view.
const close = document.querySelector(".close");
if (close && io && !reduce.matches) {
  const blink = new IntersectionObserver(([e]) => {
    if (!e.isIntersecting) return;
    close.classList.add("is-on");
    blink.disconnect();
  }, { threshold: 0.6 });
  blink.observe(close);
}
