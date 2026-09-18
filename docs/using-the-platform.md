# Using the platform

For the people who will work with UnderstandTech every day. You do not need to
know anything about the machine it runs on.

If you are the one who installs or operates that machine, you want
[installing](install.md) instead.

## What this is

Your organisation has an appliance on its own network running the
UnderstandTech platform. You reach it from a browser, on a laptop, a phone or a
tablet, like any internal website.

**It is not a service on the internet.** The models run on the machine itself.
When you ask a question or upload a document, the content stays inside your
network — which is the reason the appliance exists.

Two consequences worth knowing from the start:

- **Off the network, no access.** There is no public address. If you work from
  elsewhere, you reach it the way you reach any other internal tool — through
  your organisation's VPN, if there is one.
- **Nothing is shared outside.** A document you upload is indexed on the
  appliance and stays there.

One exception, and your administrator decides it: they can enable external
model providers. If they have, the platform offers those models next to the
local one, and **a question sent to one of them leaves the network**. Ask which
models are enabled where you work; the answer is a policy decision, not a
technical accident.

## Where to go

Everything hangs off one address, the one your administrator gives you. If it
is `understand.local`, the addresses are:

| Address | What you do there |
|---|---|
| `https://understand.local` | The platform — conversations, your documents, your workspace |
| `https://llms.understand.local` | Browse the available models and try them side by side |
| `https://assistants.understand.local` | Build and run assistants |
| `https://builder.understand.local` | Describe an application and have it built |
| `https://<name>.apps.understand.local` | An application that was built here, one address per application |
| `https://admin.understand.local` | Administration — users and tenants. Most people have no reason to open this one |

The App Builder and the applications it generates are an add-on. If your
appliance does not have it, those two addresses do not answer.

## Signing in

You sign in with your usual work account, through your organisation's identity
provider — the same credentials and the same second factor you use elsewhere.

**There is no separate username and password for this platform.** If sign-in
fails, the problem is almost always on the identity provider's side, not the
appliance's: an account not yet authorised for this application, an expired
session, a second factor that was not completed. Your IT support handles it,
not the person who runs the box.

Who may sign in at all is decided in your identity provider. Being able to
reach the address is not the same as having an account.

## The first time: a certificate warning

On many installations the browser objects on the first visit — *"Your
connection is not private"*, *"Potential security risk ahead"*, or similar.

**This is expected, and the connection is genuinely encrypted.** The appliance
signs its own certificate, and your browser has no reason to trust that signer
yet. It is not an interception and it is not a misconfiguration.

Two ways out, and only your administrator can pick:

- They install the appliance's root certificate on the machines that use it —
  often pushed automatically through device management. The warning then
  disappears for good and you see a normal padlock.
- Or they obtain a publicly trusted certificate for the appliance, and nothing
  has to be installed on your machine at all.

Until one of those is done you can click through the warning, but say so to
whoever runs the appliance — clicking through a certificate warning is a habit
worth not building.

## What you can do

**Ask questions of a model.** The built-in assistant, Understand AI, runs on
the appliance's own GPU. If your administrator has enabled external providers,
you can pick one of those instead per conversation.

**Bring your documents.** Upload files and ask questions about their content.
Indexing happens on the appliance.

**Connect a data source.** If your administrator has set one up, you can reach
documents and records from OneDrive, SharePoint, HubSpot or Zoho without
copying them by hand.

**Build an assistant.** An assistant is a model plus instructions plus the
documents it is allowed to consult, saved so you and your colleagues can reuse
it.

**Build an application.** With the App Builder add-on, describe what you want
and it generates a working application, served from the same appliance.

## When something does not work

| What you see | What it usually means | Who fixes it |
|---|---|---|
| The address does not resolve at all | You are not on the right network, or you are off the VPN | You, then your IT support |
| The browser warns about the certificate | Normal on first visit — see above | Your administrator, once |
| Sign-in is refused | Your account is not authorised for this application | Your IT support |
| A page loads but answers are slow or fail | A service on the appliance needs attention | Whoever operates the appliance |
| A model you expect is not in the list | It has not been enabled | Your administrator |

When you report a problem, say **which address** you were on and **what time**
it happened. Both narrow it down immediately for whoever looks into it.

## What this document does not cover

The screen-by-screen detail of each surface — where a button is, what a panel
is called — is not here, and is not in this repository: these pages come from
the application itself, which is published separately. This document covers
what is decided by the way your appliance is deployed. For the rest, the
product's own guide is the source.
