# Licensing

What a license controls, where it lives, and how it is issued, checked and
released. The step-by-step commands stay on the pages that run them — this page
is the cross-cutting picture, for whoever has to reason about a license rather
than type one command.

## What a license governs

A license binds to one machine. Only a machine with a valid one can sign in to
the registry: the key carries the registry access, so a box with no license
pulls nothing. It names the customer, the machine, an expiry date and the
registry the images come from — `ghcr.io` for most boxes, a customer's own
mirror when one is configured.

Two files on the box, both readable by root only:

| File | Holds |
|---|---|
| `/etc/understandtech/license` | the license key itself |
| `/etc/understandtech/machine.lic` | the signed file Keygen issued for this machine's fingerprint |

The fingerprint is drawn from the machine's hardware serial number, or, absent
one, from `/etc/machine-id` — which a reinstall changes, so a machine with no
serial number re-activates after a reinstall. `ut-license --fingerprint` is not
a command; the fingerprint is computed by `ut-install` and `ut-license`
themselves and never printed on its own, to keep it out of logs and tickets.

## Activating a license

Covered step by step in [installing](install.md#5--configure-and-start): the
key is asked for or read from `--license-file`/`UT_LICENSE`, activated with
Keygen on the first install, and checked from `machine.lic` with no network on
every run after that. A machine that cannot reach Keygen is activated instead
by a file exchange — `license-request.json` out, a signed `.lic` file back —
also described there.

`ut-license` is the tool behind all of it:

```text
ut-license activate KEY_FILE MACHINE_FILE   activate this machine with Keygen,
                                             and write the signed file
ut-license check MACHINE_FILE               who it is licensed to, and until when
ut-license field NAME MACHINE_FILE          one field of a valid machine file,
                                             for ut-install to read
ut-license request                          what a machine with no network sends
                                             to UnderstandTech
```

`ut-license activate` exits `3` when Keygen cannot be reached, which is what
tells `ut-install` to fall back to the file exchange instead of failing outright.

## Checking a license

```bash
sudo ut-license check /etc/understandtech/machine.lic
```

Reports the customer, the machine and the expiry date without installing or
changing anything. `sudo ut-status` reports the same expiry date alongside every
other service, as part of its routine verdict.

## When a license ends

An ended license stops an **install or an update**, with the date it ended. It
never stops a **running** platform: the boot service logs the expiry to the
journal and starts the stack regardless. The next update asks Keygen whether the
license was renewed before it proceeds — see
[what changes that you will notice](update.md#what-changes-that-you-will-notice)
for what else an update touches.

A key of the old format (`UT1.…`) is refused outright, and a license already
active on another machine is refused too — both need UnderstandTech to issue a
new one or release the old one.

## Issuing a license (UnderstandTech)

Two scripts under `packaging/` do this; they are not run on a customer's box.

- `packaging/issue-license.sh --customer <name> --machine <name> --expires <date> --token-file <registry token> --keygen-token-file <keygen token>` —
  issues a new license in Keygen for a customer and machine, carrying the
  registry token that machine will pull with, and records it in a ledger file.
- `packaging/activate-a-machine.sh --customer <name> --machine <name> --request <license-request.json> --keygen-token-file <keygen token>` —
  takes the request a disconnected box wrote and returns the signed `.lic` file
  to send back, for `sudo ut-install --machine-file <file> --skip-pull`.

Both need a Keygen token scoped to issuing or activating this product's
licenses, never the customer's own registry token.

## Releasing a license

When a machine is decommissioned, ask UnderstandTech to release its license so
it can activate on another machine and have the registry token revoked — a
license is per-deployment, not reusable by copying the file. See
[decommissioning](decommissioning.md#1--decide-what-has-to-survive) for the rest
of what a retired box leaves behind.

## What this document does not cover

How Keygen itself is configured, or the policy named `AI in a Box, one machine,
one year` — both live in Keygen, not in this repository. Pricing and contract
terms are not a licensing mechanism and are not covered here.
