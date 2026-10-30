"use strict";

const $ = (id) => document.getElementById(id);

async function ask(path) {
  const answer = await fetch(path);
  if (answer.status === 401) {
    location.replace("/");
    throw new Error("signed out");
  }
  if (!answer.ok) throw new Error((await answer.text()).trim() || answer.statusText);
  return answer;
}

function showTheTabTheAddressNames() {
  const wanted = (location.hash || "#overview").slice(1);
  const tab = ["overview", "logs", "activity"].includes(wanted) ? wanted : "overview";
  document.querySelectorAll(".tab").forEach((section) => { section.hidden = section.id !== tab; });
  document.querySelectorAll(".side a").forEach((link) => {
    if (link.getAttribute("href") === "#" + tab) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
  if (tab === "activity") readTheActivity();
}

function check(kind, text) {
  const item = document.createElement("li");
  item.className = kind;
  const mark = document.createElement("b");
  mark.textContent = kind === "ok" ? "✓" : "!";
  const words = document.createElement("span");
  words.textContent = text;
  item.append(mark, words);
  return item;
}

function cell(text) {
  const td = document.createElement("td");
  td.textContent = text;
  return td;
}

function row(...texts) {
  const tr = document.createElement("tr");
  tr.append(...texts.map(cell));
  return tr;
}

const gigabytes = (bytes) => (bytes / 1e9).toFixed(0) + " GB";
const when = (iso) => iso ? new Date(iso).toLocaleString() : "";

function summary(status) {
  const items = [];
  items.push(check(status.release ? "ok" : "warn", status.release ? `Release ${status.release}` : "The installed release is not known"));
  const services = status.services || [];
  const down = services.filter((s) => s.state !== "running" || s.health === "unhealthy");
  if (!services.length) items.push(check("warn", "No service could be listed: Docker does not answer"));
  else items.push(check(down.length ? "warn" : "ok", down.length
    ? `${services.length - down.length} of ${services.length} services running — not: ${down.map((s) => s.name).join(", ")}`
    : `${services.length} services running`));
  items.push(check("ok", status.model ? `Model ${status.model}` : "Model: the one this release ships"));
  items.push(check(status.last_backup ? "ok" : "warn", status.last_backup ? `Last file backup ${when(status.last_backup)}` : "No file backup found"));
  for (const disk of status.disks || []) {
    const low = disk.available_bytes < disk.total_bytes * 0.15;
    items.push(check(low ? "warn" : "ok", `Disk ${disk.path}: ${gigabytes(disk.available_bytes)} free of ${gigabytes(disk.total_bytes)}`));
  }
  items.push(check(status.license_until ? "ok" : "warn", status.license_until ? `License until ${status.license_until}` : "The license's end is not known"));
  items.push(check("ok", status.reporting || "Usage reports: not known"));
  return items;
}

async function readTheBox() {
  $("overview-loading").hidden = false;
  $("overview-failed").hidden = true;
  try {
    const status = await (await ask("/api/status")).json();
    $("domain").textContent = status.domain || "";
    $("summary").replaceChildren(...summary(status));
    $("services").replaceChildren(...(status.services || []).map((s) => row(s.name, s.state, s.health || "—", `${s.running} of ${s.replicas}`)));
    const chosen = $("service").value;
    $("service").replaceChildren(...(status.services || []).map((s) => {
      const option = document.createElement("option");
      option.value = option.textContent = s.name;
      return option;
    }));
    if (chosen) $("service").value = chosen;
  } catch (failure) {
    $("overview-failed").textContent = failure.message;
    $("overview-failed").hidden = false;
  } finally {
    $("overview-loading").hidden = true;
  }
}

async function readTheLogs(event) {
  event.preventDefault();
  $("logs-failed").hidden = true;
  const query = new URLSearchParams({ service: $("service").value, lines: $("lines").value });
  try {
    $("log-lines").textContent = await (await ask("/api/logs?" + query)).text();
    $("log-lines").hidden = false;
  } catch (failure) {
    $("logs-failed").textContent = failure.message;
    $("logs-failed").hidden = false;
  }
}

async function readTheActivity() {
  $("activity-failed").hidden = true;
  try {
    const lines = await (await ask("/api/activity?limit=200")).json();
    $("activity-lines").replaceChildren(...lines.map((l) => row(when(l.at), l.who, l.action, l.result, l.detail || "")));
  } catch (failure) {
    $("activity-failed").textContent = failure.message;
    $("activity-failed").hidden = false;
  }
}

$("sign-out").addEventListener("click", async () => {
  await fetch("/sign-out", { method: "POST" });
  location.replace("/");
});
$("refresh").addEventListener("click", readTheBox);
$("logs-form").addEventListener("submit", readTheLogs);
addEventListener("hashchange", showTheTabTheAddressNames);
showTheTabTheAddressNames();
readTheBox();
