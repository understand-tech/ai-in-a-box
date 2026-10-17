"use strict";

const $ = (id) => document.getElementById(id);
const show = (id, visible = true) => { $(id).hidden = !visible; };

async function progress() {
  const answer = await fetch("/progress");
  if (!answer.ok) return null;
  return answer.json();
}

function render(p) {
  show("questions", !p.running && !p.finished);
  show("running", p.running || (p.finished && !p.succeeded));
  show("done", p.finished && p.succeeded);
  $("step").textContent = p.step || "Starting";
  show("images", p.total > 0);
  $("images").max = p.total;
  $("images").value = p.landed;
  $("count").textContent = p.total > 0 ? `${p.landed} of ${p.total} images on the box` : "";
  $("failure").textContent = p.failure;
  show("failure", p.finished && !p.succeeded);
  show("again", p.finished && !p.succeeded);
  $("lines").textContent = p.lines.join("\n");
}

async function follow() {
  const p = await progress();
  if (!p) return;
  render(p);
  $("open").href = `https://${p.domain}`;
  if (p.running) setTimeout(follow, 2000);
}

$("questions").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = new FormData(event.target);
  const answer = await fetch("/install", { method: "POST", body: new URLSearchParams(form) });
  if (!answer.ok) {
    $("refused").textContent = await answer.text();
    show("refused");
    return;
  }
  follow();
});

$("again").addEventListener("click", () => {
  show("running", false);
  show("questions");
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
});

$("written").addEventListener("change", (event) => {
  show("open", event.target.checked);
});

follow();
