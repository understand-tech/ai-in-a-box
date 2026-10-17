# The usage report

How many people a box really serves decides when a second one is worth adding.
The box can measure it; we cannot, since we have no access to it. This page is
for the operator asked to send us reports, and for whoever has to approve what
leaves the network.

## Sending them on their own

Nothing leaves the machine until someone answers yes. `ut-install` asks once,
with no answer preselected; with no terminal and no `--reporting`, the answer is
no. The same answer can be given, or changed, at any time:

```bash
sudo ut-send configure --consent yes --receiver https://<receiver>:8444 \
    --token-file <token file> --receiver-cert <receiver certificate> [--every 15]
sudo ut-send configure --consent no
```

`ut-install` takes the same details as `--reporting yes`,
`--reporting-receiver`, `--reporting-token-file`, `--reporting-receiver-cert`
and `--reporting-every`. The receiver, token and certificate can come later:
until they are given, what is written waits on the machine.

A yes installs a systemd timer, `ut-send.timer`. Every 15 minutes — or as many
minutes as `--every` says, from 1 to 1440 — it:

1. puts in line what the `metrics` service recorded since the last pass, with
   the platform's address replaced by the name of the surface it serves
   (`app`, `llms`, …);
2. once an hour — or at every pass, when passes are more than an hour apart —
   puts in line the report described below, with the health of the stack and
   the use of each tool;
3. sends what is in line to the receiver, over HTTPS, trusting only the
   receiver's certificate it was given.

What the receiver does not accept stays in line and is tried again on the next
pass, for up to 7 days or 200 MB, the oldest given up first. A token the
receiver refuses stops the sending until a new one is given with
`ut-send configure`.

A no stops and removes the timer, deletes what was waiting to be sent, and
forgets the receiver and the token.
Removing the package removes the timer too; an upgrade keeps it.

`sudo ut-status` and `sudo ut-send status` say whether reports go out, where,
how often, when the receiver last accepted one, and how many wait:

```text
==> Usage reports
[ ok ] Reporting: on, to fleet.example.com:8444, every 15 minutes
[ ok ] last accepted 2026-10-14T12:15:03Z, 0 waiting
```

What goes out on top of the report below:

- **health**: for each service, how many copies run and whether they are
  healthy; the background queues and how many jobs wait or failed; space on the
  disks the platform writes to; for each inference engine, the model it serves
  and the GPU memory it holds; when the last backup ran; the validity dates of
  the HTTPS certificates; whether the clock is synchronised;
- **use of each tool**: requests per hour, and people over the last 7 days, per
  tool of the platform — counts only, and a tool the platform does not ship is
  counted as `other`, never by its name;
- **the recorder's figures**: the engines', the model gateway's and the front
  door's counters, at the recorder's resolution. Requests are counted per
  surface, never per address.

## Writing one by hand

```bash
sudo ut-report
```

It writes a directory named `ut-report-<date>` in the current directory, or in
the one given with `--out`. `--days` shortens the window, which is 30 days by
default. This one is not sent: passing the directory on is a step you take
yourself.

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
  and waiting at once, how many minutes at least one request waited, how many
  got their first token within 1 s and within 2.5 s, and how many prompts were
  up to 500, 2,000 and 10,000 tokens long;
- per hour: how many distinct people sent a request — a number, never who;
- for each service: the memory it uses, the most it has used since it started,
  and its limit, if it has one; and the machine's total and available memory.
  What an engine holds on the GPU is counted in no service — on a machine whose
  GPU shares the system's memory, only the machine's available memory includes
  it. `ut-status` notes that figure with each hourly verdict, so the history
  shows how close the box came to running out;
- every run of `ut-install` and every `ut-status` verdict on this machine;
- the release, and the image each service runs.

**What it never holds**: no document, conversation, prompt, answer or extract of
one; no user name, e-mail address, API key or IP address; no setting, password
or secret, and not this machine's address. The machine is named by an identifier
drawn at random the first time a report is written, kept in
`/var/lib/understandtech/install-id`.

## Where the numbers come from

The recorder's figures are kept by the `metrics` service, which runs on every
machine and publishes no port: the engines' own counters where an engine runs,
the model gateway's and the front door's wherever the platform runs. It keeps
35 days, or 1 GB, whichever comes first — see [the stack](the-stack.md).

The number of people per hour is counted inside the database container, from the
platform's records of who sent a request, and only the count leaves it.

Response times are counts against fixed bounds rather than percentiles. The
engines measure them in steps with nothing between 1 s and 2.5 s, so a
percentile read in between is a guess; a count is exact. The bounds are
cumulative: a request within 1 s is also counted within 2.5 s. The same holds for
prompt sizes.

## When a figure is missing

A report never fills a gap with zero. What it could not find is listed under
`warnings`, and `ut-report` prints the list:

| Warning | Means |
|---|---|
| `recorder-missing` | An engine runs on this machine and the `metrics` service recorded nothing: it is stopped, or was never started. `sudo ut-status` names it. |
| `series-missing:<engine>:<figure>` | The recorder has nothing for that figure over the window: it was not running, or the engine names it differently since an update. |
| `memory-peak-unknown:<service>` | The kernel does not keep a memory peak for that service (cgroup v1, or a kernel older than 5.19). Its current use is still given. |
| `users-missing` | The engines served requests and no person was counted. The platform's records were not readable, or have changed shape. |
| `recorder-budget-short` | At the pace the recorder has filled its disk so far, its size cap holds fewer days than it is set to keep. Nothing is lost yet: once over the cap, the recorder drops its oldest days without a word, and the window this report covers shrinks with them. Raise the cap, or record less. |

A machine that serves no inference — a control plane whose engines run
elsewhere — reports an empty `capacity` list, without a warning. A machine that
runs no database, such as a compute node, reports an empty `users_by_hour`.
