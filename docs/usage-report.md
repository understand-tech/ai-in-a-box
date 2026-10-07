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
  and waiting at once, how many got their first token within 1 s and within
  2.5 s, and how many prompts were up to 500, 2,000 and 10,000 tokens long;
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

The engine figures are kept by the `metrics` service, which records the
engines' own counters on the machine that runs them and publishes no port. It
keeps 35 days, or 1 GB, whichever comes first — see [the stack](the-stack.md).

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

A machine that serves no inference — a control plane whose engines run
elsewhere — reports an empty `capacity` list, without a warning. A machine that
runs no database, such as a compute node, reports an empty `users_by_hour`.
