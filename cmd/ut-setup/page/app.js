"use strict";

const $ = (id) => document.getElementById(id);
const show = (id, visible = true) => { $(id).hidden = !visible; };

const screens = ["check", "update", "role", "domain", "node", "compute", "tls", "license", "model", "reporting", "running", "done"];
const askable = ["role", "domain", "node", "compute", "tls", "license", "model", "reporting"];
const skipped = { complete: ["node", "compute"], platform: ["compute"], compute: ["domain", "node", "tls"] };
let questions = [...askable];
let updating = false;
let fromFolder = false;
let licenseFromFolder = false;
let installedRole = "";
const roles = { appliance: "Complete box: the platform and its inference", compute: "Inference only, served to another box" };
const marks = { ok: ["✓", ""], done: ["✓", ""], current: ["…", ""], warn: ["⚠", "Warning: "], fail: ["✕", "Problem: "] };
const unmarked = ["", ""];

function chosen(name) {
  const input = document.querySelector(`input[name=${name}]:checked`);
  return input ? input.value : "";
}

function refreshQuestions() {
  if (updating) {
    questions = [];
    return;
  }
  questions = askable.filter((name) => !(skipped[chosen("role")] || skipped.complete).includes(name)
    && !(fromFolder && name === "reporting") && !(licenseFromFolder && name === "license"));
}

function refreshTLS() {
  for (const [kind, block, input] of [["certificate", "certificate-block", "certificate-input"], ["proxy", "proxy-block", "proxy-input"]]) {
    const picked = chosen("tls") === kind;
    show(block, picked);
    $(input).disabled = !picked;
  }
}

function go(screen) {
  for (const name of screens) show(name, name === screen);
  const reached = screens.indexOf(screen);
  document.querySelectorAll(".dots li").forEach((dot) => {
    const index = screens.indexOf(dot.dataset.for);
    dot.hidden = (askable.includes(dot.dataset.for) && !questions.includes(dot.dataset.for)) || (dot.dataset.for === "update" && !updating);
    dot.classList.toggle("on", index <= reached);
    dot.toggleAttribute("aria-current", index === reached);
  });
  const asked = questions.indexOf(screen);
  if (asked >= 0) {
    $(screen).querySelector(".count").textContent = `Question ${asked + 1} of ${questions.length}${screen === "model" ? " · optional" : ""}`;
    $(screen).querySelector("button.primary").textContent = asked === questions.length - 1 ? "Install" : "Continue";
  }
  const first = $(screen).querySelector("input:not([type=radio]), input[type=radio]:checked, button.primary:not(:disabled)");
  if (first) first.focus();
}

function current() {
  return screens.find((name) => !$(name).hidden);
}

function item(text, kind, [sign, word] = marks[kind]) {
  const li = document.createElement("li");
  li.className = kind;
  if (sign) {
    const mark = document.createElement("b");
    mark.textContent = sign;
    li.append(mark);
  }
  const words = document.createElement("span");
  words.textContent = word + text;
  li.append(words);
  return li;
}

function minutes(seconds) {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

async function readiness() {
  const answer = await fetch("/check");
  if (!answer.ok) return;
  const check = await answer.json();
  $("readiness").replaceChildren(...check.messages.map((m) => item(m.text, m.kind)));
  if (check.installed) showInstalled(check.installed);
  const verb = updating ? "updated" : "installed";
  $("check-title").textContent = check.ready ? `This box can be ${verb}` : `This box cannot be ${verb} as it is`;
  if (check.from_folder) {
    fromFolder = true;
    licenseFromFolder = check.license_from_folder;
    refreshQuestions();
    $("from-folder").textContent = `The images come from the folder ut-get was given${check.license_from_folder ? ", and so does the license" : ""}. A box with no network sends no usage reports, so that question is not asked.`;
    show("from-folder");
  }
  show("checking", false);
  show("check-lead", check.ready);
  show("not-ready", !check.ready);
  $("checked").disabled = !check.ready;
  if (current() === "check") go("check");
}

function showInstalled(installed) {
  updating = true;
  installedRole = installed.role;
  refreshQuestions();
  document.querySelector('.dots li[data-for="running"]').textContent = "Update";
  $("installed-role").textContent = roles[installed.role] || `Platform; its inference comes from ${installed.node || "another box"}`;
  $("installed-address").textContent = installed.address;
  $("installed-model").textContent = installed.model || "The model its release ships";
  const same = installed.installed === installed.release;
  $("installed-release").textContent = same ? `${installed.release}, the one this package carries` : `${installed.installed || "unknown"} → ${installed.release}`;
  $("update-button").textContent = same ? "Run the install again" : `Update to ${installed.release}`;
}

function modelOption(model) {
  const label = document.createElement("label");
  label.className = "option";
  const input = document.createElement("input");
  input.type = "radio";
  input.name = "model";
  input.value = model.id;
  const words = document.createElement("span");
  const name = document.createElement("b");
  name.textContent = model.id;
  const facts = document.createElement("small");
  facts.textContent = [model.served, model.size, model.license].join(" · ");
  words.append(name, facts);
  if (model.runs_its_own_code) {
    const tag = document.createElement("em");
    tag.textContent = "⚠ runs code of its own";
    words.append(tag);
  }
  label.append(input, words);
  return label;
}

async function models() {
  const answer = await fetch("/models");
  if (!answer.ok) return;
  const shipped = $("models").firstElementChild;
  $("models").replaceChildren(shipped, ...(await answer.json()).map(modelOption));
}

function render(p) {
  const done = p.finished && p.succeeded;
  const failed = p.finished && !p.succeeded;
  const screen = done ? "done" : p.running || failed ? "running" : "";
  if (screen && current() !== screen) go(screen);

  $("step").textContent = p.running ? p.step || "Starting" : "Stopped";
  $("running-title").textContent = p.update ? (failed ? "The update stopped" : "Updating") : failed ? "The install stopped" : "Installing";
  $("keep-open").textContent = p.update ? "Keep this page open until it says the box is up to date." : "Keep this page open: the two passwords appear here, once, at the end.";
  show("working", p.running);
  $("elapsed").textContent = minutes(p.elapsed);
  show("images-block", p.total > 0 && p.running);
  $("images").max = p.total;
  $("images").value = p.landed;
  $("landed").textContent = p.landed;
  $("total").textContent = p.total;

  $("steps").replaceChildren(...p.steps.map((name, index) => {
    const last = index === p.steps.length - 1;
    if (!last) return item(name, "done");
    if (failed) return item(name, "fail");
    return item(name, p.running ? "current" : "done");
  }));

  const warnings = p.messages.filter((m) => m.kind === "warn");
  $("warnings").replaceChildren(...warnings.map((m) => item(m.text, "warn", unmarked)));
  show("warnings-block", warnings.length > 0);
  show("keep-open", p.running);

  show("failure-block", failed);
  $("failed-step").textContent = p.step || "the start";
  $("failures").replaceChildren(...p.messages.filter((m) => m.kind === "fail").map((m) => item(m.text, "fail", unmarked)));

  const pre = $("lines");
  const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 4;
  pre.textContent = p.lines.join("\n");
  if (atBottom) pre.scrollTop = pre.scrollHeight;

  $("took").textContent = done ? `in ${Math.max(1, Math.round(p.elapsed / 60))} min` : "";
  $("done-title").textContent = p.update ? "Up to date" : "Installed";
  if (p.update) $("done-next").textContent = "Its accounts, documents and settings are as they were.";
  if (p.compute) {
    $("done-where").textContent = "A platform takes its inference from it at";
    $("done-next").textContent = "It serves the platforms paired with it, and no other.";
  }
  if (p.platform) $("done-next").textContent = "It answers once paired with its compute node, below. The initial admin password then opens its first-run wizard.";
  show("pair-offer", done && (p.compute || installedRole === "compute"));
  show("pair-join", done && p.platform);
  show("passwords-warning", !p.update && !p.compute);
  show("reveal", !p.update && !p.compute && $("secrets").hidden);
  if (p.update) {
    show("open-block");
    $("open").setAttribute("aria-disabled", "false");
    $("open").tabIndex = 0;
  }
  $("address").textContent = p.compute ? p.domain : `https://${p.domain}`;
  if (p.compute) $("address").removeAttribute("href");
  else $("address").href = `https://${p.domain}`;
  $("open").href = `https://${p.domain}`;
}

async function follow() {
  let answer;
  try {
    answer = await fetch("/progress");
  } catch {
    setTimeout(follow, 2000);
    return;
  }
  if (!answer.ok) return;
  const p = await answer.json();
  render(p);
  if (!p.running && !p.finished) {
    go("check");
    readiness();
    models();
  }
  if (p.running) setTimeout(follow, 2000);
}

function answered(screen) {
  return [...$(screen).querySelectorAll("input")].every((input) => input.reportValidity());
}

async function install() {
  show("refused", false);
  const answer = await fetch("/install", { method: "POST", body: new URLSearchParams(new FormData($("answers"))) });
  if (!answer.ok) {
    $("refused").textContent = await answer.text();
    show("refused");
    return;
  }
  go("running");
  follow();
}

$("checked").addEventListener("click", () => go(updating ? "update" : questions[0]));

for (const input of document.querySelectorAll("input[name=role]")) {
  input.addEventListener("change", () => { refreshQuestions(); go("role"); });
}

for (const input of document.querySelectorAll("input[name=tls]")) {
  input.addEventListener("change", refreshTLS);
}

$("update-back").addEventListener("click", () => go("check"));

$("update-button").addEventListener("click", async () => {
  show("update-refused", false);
  const answer = await fetch("/update", { method: "POST" });
  if (!answer.ok) {
    $("update-refused").textContent = await answer.text();
    show("update-refused");
    return;
  }
  go("running");
  follow();
});

$("answers").addEventListener("submit", (event) => {
  event.preventDefault();
  const screen = current();
  if (!answered(screen)) return;
  const next = questions[questions.indexOf(screen) + 1];
  if (next) go(next);
  else install();
});

for (const back of document.querySelectorAll(".back")) {
  back.addEventListener("click", () => go(["check", ...questions][["check", ...questions].indexOf(current()) - 1]));
}

$("show-license").addEventListener("click", (event) => {
  const visible = $("license-input").type === "password";
  $("license-input").type = visible ? "text" : "password";
  event.target.textContent = visible ? "Hide" : "Show";
  event.target.setAttribute("aria-pressed", String(visible));
});

$("again").addEventListener("click", () => go(updating ? "update" : questions[questions.length - 1]));

function said(id, text) {
  $(id).textContent = text.charAt(0).toUpperCase() + text.slice(1);
  show(id, text !== "");
}

async function followThePairing() {
  const answer = await fetch("/pairing");
  if (!answer.ok) return;
  const pairing = await answer.json();
  $("offer-code").textContent = pairing.code;
  $("offer-until").textContent = pairing.until;
  show("offer-shown", pairing.running && pairing.code !== "");
  if (pairing.paired) said("offer-said", `Paired with the platform at ${pairing.paired}.`);
  else if (pairing.problem) said("offer-said", pairing.problem);
  else said("offer-said", "");
  show("offer", !pairing.running);
  if (pairing.running) setTimeout(followThePairing, 2000);
}

$("offer").addEventListener("click", async () => {
  const answer = await fetch("/offer", { method: "POST" });
  if (!answer.ok) {
    said("offer-said", await answer.text());
    return;
  }
  show("offer", false);
  followThePairing();
});

$("pair-join").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("pair").disabled = true;
  said("pair-said", "Pairing… this takes up to a minute.");
  const answer = await fetch("/pair", { method: "POST", body: new URLSearchParams(new FormData($("pair-join"))) });
  $("pair").disabled = false;
  if (!answer.ok) {
    said("pair-said", await answer.text());
    return;
  }
  const pairing = await answer.json();
  said("pair-said", `Paired with the compute node at ${pairing.paired}.`);
  $("pair").disabled = true;
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

refreshQuestions();
follow();
