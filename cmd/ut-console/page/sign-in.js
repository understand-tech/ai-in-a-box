"use strict";

document.getElementById("sign-in").addEventListener("submit", async (event) => {
  event.preventDefault();
  const password = document.getElementById("password");
  const answer = await fetch("/sign-in", { method: "POST", body: new URLSearchParams({ password: password.value }) });
  password.value = "";
  if (answer.ok) {
    location.replace("/");
    return;
  }
  const refused = document.getElementById("refused");
  refused.textContent = await answer.text();
  refused.hidden = false;
});
