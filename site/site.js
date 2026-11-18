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

// The hero slot's loop runs forever, so it gets a Pause control once its animations exist.
const slot = document.querySelector(".hero-slot");
const pause = slot?.querySelector(".slot-pause");
const fig = slot?.querySelector("figure");
if (pause && fig) {
  const loops = () => fig.getAnimations({ subtree: true }).filter((a) => a.effect.getTiming().iterations === Infinity);
  const check = () => { pause.hidden = reduce.matches || !loops().length; };
  document.fonts.ready.then(() => requestAnimationFrame(check));
  reduce.addEventListener("change", () => requestAnimationFrame(check));
  pause.addEventListener("click", () => {
    const paused = slot.classList.toggle("is-paused");
    pause.setAttribute("aria-pressed", paused);
    pause.textContent = paused ? "Play" : "Pause";
    for (const a of loops()) paused ? a.pause() : a.play();
  });
}

// The scene: the writers are tabs. A selected tab's bar fills (styles.css), and its end selects the
// next. The bar holds while the scene is off screen or the page is hidden; choosing a tab stops it.
const scene = document.querySelector(".scene");
const tabs = scene ? [...scene.querySelectorAll('[role="tab"]')] : [];
if (tabs.length) {
  const select = (tab, focus) => {
    for (const t of tabs) {
      const on = t === tab;
      t.setAttribute("aria-selected", on);
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).classList.toggle("on", on);
    }
    if (focus) tab.focus();
  };
  const by = (d) => tabs[(tabs.findIndex((t) => t.tabIndex === 0) + d + tabs.length) % tabs.length];
  for (const t of tabs) {
    t.addEventListener("click", () => { scene.classList.add("is-chosen"); select(t); });
    t.querySelector(".seg i").addEventListener("animationend", () => select(by(1)));
  }
  scene.querySelector('[role="tablist"]').addEventListener("keydown", (e) => {
    const d = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
    const t = d ? by(d) : e.key === "Home" ? tabs[0] : e.key === "End" ? tabs[tabs.length - 1] : null;
    if (!t) return;
    e.preventDefault();
    scene.classList.add("is-chosen");
    select(t, true);
  });
  let seen = !io;
  const sync = () => {
    scene.classList.toggle("is-live", !reduce.matches);
    scene.classList.toggle("is-held", !seen || document.hidden);
  };
  if (io) new IntersectionObserver(([e]) => { seen = e.intersectionRatio >= 0.3; sync(); }, { threshold: [0, 0.3] }).observe(scene);
  document.addEventListener("visibilitychange", sync);
  reduce.addEventListener("change", sync);
  sync();
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
