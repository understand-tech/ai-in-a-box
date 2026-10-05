# The usage report

How many people a box really serves decides when a second one is worth adding.
The box can measure it; we cannot, since we have no access to it. This page is
for the operator asked to send us a report, and for whoever has to approve what
leaves the network.

## Writing one

```bash
sudo ut-report
```

It writes a directory named `ut-report-<date>` in the current directory, or in
the one given with `--out`. `--days` shortens the window, which is 30 days by
default. Nothing is sent: passing the directory on is a step you take yourself.

```text
[ ok ] Report written to ./ut-report-20261005T1120Z
Read ./ut-report-20261005T1120Z/MANIFEST.txt before passing it on.
```

`sudo` is needed: the report reads the settings file, which is `0600`, and the
database, through the container that holds it.

## What is in the directory

| File | Holds |
|---|---|
| `MANIFEST.txt` | In plain text, what the report holds and what it never holds, and the report's checksum. Readable without opening anything else. |
| `report.json` | The report itself. |
| `SHA256SUMS` | The checksum, in the form `sha256sum -c` reads. |

**What the report holds**:

- per hour and per inference engine: requests served, the most requests running
  and waiting at once, and the 95th percentile time to first token;
- per hour: how many distinct people sent a request — a number, never who;
- every run of `ut-install` and every `ut-status` verdict on this machine;
- the release, and the image each service runs.

**What it never holds**: no document, conversation, prompt, answer or extract of
one; no user name, e-mail address, API key or IP address; no setting, password
or secret, and not this machine's address. The machine is named by an identifier
drawn at random the first time a report is written, kept in
`/var/lib/understandtech/install-id`.

## Where the numbers come from

The engine figures are kept by the `metrics` service, which records the
engines' own counters on the machine that runs them and publishes no port. It
keeps 35 days, or 1 GB, whichever comes first — see [the stack](the-stack.md).

The number of people per hour is counted inside the database container, from the
platform's records of who sent a request, and only the count leaves it.

## When a figure is missing

A report never fills a gap with zero. What it could not find is listed under
`warnings`, and `ut-report` prints the list:

| Warning | Means |
|---|---|
| `recorder-missing` | An engine runs on this machine and the `metrics` service recorded nothing: it is stopped, or was never started. `sudo ut-status` names it. |
| `series-missing:<engine>:<figure>` | The recorder has nothing for that figure over the window: it was not running, or the engine names it differently since an update. |
| `users-missing` | The engines served requests and no person was counted. The platform's records were not readable, or have changed shape. |

A machine that serves no inference — a control plane whose engines run
elsewhere — reports an empty `capacity` list, without a warning. A machine that
runs no database, such as a compute node, reports an empty `users_by_hour`.
