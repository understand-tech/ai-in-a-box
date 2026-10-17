"use strict";

const $ = (id) => document.getElementById(id);
const show = (id, visible = true) => { $(id).hidden = !visible; };

function item(text, kind) {
  const li = document.createElement("li");
  const marks = { ok: "✓ ", warn: "⚠ Warning: ", bad: "✕ Problem: ", current: "… ", done: "✓ " };
  li.className = kind;
  li.textContent = (marks[kind] || "") + text;
  return li;
}

function stage(current) {
  const order = ["answers", "install", "done"];
  order.forEach((name, index) => {
    const li = $(`stage-${name}`);
    li.toggleAttribute("aria-current", name === current);
    if (name === current) li.setAttribute("aria-current", "step");
    li.classList.toggle("passed", index < order.indexOf(current));
  });
}

function minutes(seconds) {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

async function readiness() {
  const answer = await fetch("/check");
  if (!answer.ok) return;
  const check = await answer.json();
  const list = $("readiness");
  list.replaceChildren();
  for (const line of check.lines) {
    if (line.startsWith("[ ok ] ")) list.append(item(line.slice(7), "ok"));
    else if (line.startsWith("[warn] ")) list.append(item(line.slice(7), "warn"));
    else if (line.startsWith("[fail] ")) list.append(item(line.slice(7), "bad"));
  }
  show("checking", false);
  show("not-ready", !check.ready);
  $("install").disabled = !check.ready;
}

function render(p) {
  const answering = !p.running && !p.finished;
  const done = p.finished && p.succeeded;
  stage(done ? "done" : answering ? "answers" : "install");
  show("questions", answering);
  show("running", p.running || (p.finished && !p.succeeded));
  show("done", done);

  $("step").textContent = p.running ? p.step || "Starting" : "Stopped";
  $("elapsed").textContent = minutes(p.elapsed);
  show("images-block", p.total > 0 && p.running);
  $("images").max = p.total;
  $("images").value = p.landed;
  $("count").textContent = `${p.landed} of ${p.total} images on the box`;

  const steps = $("steps");
  steps.replaceChildren();
  p.steps.forEach((name, index) => {
    const last = index === p.steps.length - 1;
    steps.append(item(name, last ? (p.finished && !p.succeeded ? "bad" : p.running ? "current" : "done") : "done"));
  });

  $("warnings").replaceChildren(...p.warnings.map((w) => item(w, "")));
  show("warnings-block", p.warnings.length > 0);

  show("failure-block", p.finished && !p.succeeded);
  $("failed-step").textContent = p.step || "the start";
  $("failure").textContent = p.failure;

  const pre = $("lines");
  const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 4;
  pre.textContent = p.lines.join("\n");
  if (atBottom) pre.scrollTop = pre.scrollHeight;

  $("took").textContent = done ? `in ${Math.max(1, Math.round(p.elapsed / 60))} min` : "";
  $("address").textContent = `https://${p.domain}`;
  $("address").href = `https://${p.domain}`;
  $("open").href = `https://${p.domain}`;
}

async function follow() {
  const answer = await fetch("/progress");
  if (!answer.ok) return;
  const p = await answer.json();
  render(p);
  if (!p.running && !p.finished) readiness();
  if (p.running) setTimeout(follow, 2000);
}

$("answers").addEventListener("submit", async (event) => {
  event.preventDefault();
  show("refused", false);
  const answer = await fetch("/install", { method: "POST", body: new URLSearchParams(new FormData(event.target)) });
  if (!answer.ok) {
    $("refused").textContent = await answer.text();
    show("refused");
    return;
  }
  follow();
});

$("show-license").addEventListener("click", (event) => {
  const visible = $("license").type === "password";
  $("license").type = visible ? "text" : "password";
  event.target.textContent = visible ? "Hide" : "Show";
  event.target.setAttribute("aria-pressed", String(visible));
});

$("again").addEventListener("click", () => {
  show("running", false);
  show("questions");
  stage("answers");
  $("license").focus();
});

$("reveal").addEventListener("click", async () => {
  const answer = await fetch("/secrets", { method: "POST" });
  show("reveal", false);
  if (!answer.ok) {
    $("admin").textContent = await answer.text();
    show("secrets");
    return;
  }
  const secrets = await answer.json();
  $("admin").textContent = secrets.admin_password;
  $("backup").textContent = secrets.backup_password;
  show("secrets");
  show("noted");
  show("open-block");
});

for (const button of document.querySelectorAll(".copy")) {
  button.addEventListener("click", async () => {
    await navigator.clipboard.writeText($(button.dataset.copy).textContent);
    button.textContent = "Copied";
  });
}

$("written").addEventListener("change", (event) => {
  $("open").setAttribute("aria-disabled", String(!event.target.checked));
  $("open").tabIndex = event.target.checked ? 0 : -1;
});
$("open").tabIndex = -1;

follow();
