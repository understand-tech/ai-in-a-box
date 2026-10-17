"use strict";

document.getElementById("continue").addEventListener("click", async () => {
  const code = new URLSearchParams(location.search).get("code") || "";
  const answer = await fetch("/enter", { method: "POST", body: new URLSearchParams({ code }) });
  if (answer.ok) {
    location.replace("/");
    return;
  }
  const refused = document.getElementById("refused");
  refused.textContent = await answer.text();
  refused.hidden = false;
});
