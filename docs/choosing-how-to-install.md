# Choosing how to install

Six questions, in the order you meet them, each with the command or the page
that answers it. Read this before [installing](install.md): most installs need
two or three of them, never all six.

## 1 · Where will you run the install from?

| You are | Run | Then |
|---|---|---|
| At the box, on its desktop | `sudo bash ut-get --version <version> --browser` | [the browser on the box asks the rest](install.md#from-a-browser-on-the-box) |
| On another machine, over SSH | `sudo bash ut-get --version <version>` | [the terminal asks the rest](install.md#in-one-command) |
| On another machine, but you want the page | the same `--browser` command over SSH, then a tunnel | [the page through SSH](install.md#from-your-own-machine-through-ssh) |

## 2 · Does the box reach the Internet?

| It | Run | What it still needs |
|---|---|---|
| Does | `ut-get --version <version>`: it downloads the release and checks its signature | nothing |
| Does not | on a connected machine, `ut-get --prepare <folder> --version <version> --license-file license.key`; carry the folder to the box, then `ut-get --from <folder>` | [the folder carries the package, the images and the weights](install.md#in-one-command); the box checks each against the signed release and downloads nothing |

## 3 · How will people reach it?

| Your site has | Give the installer | People's machines need |
|---|---|---|
| No DNS server, one flat network | `understand.local` | nothing on macOS; [two changes on Linux](certificates-and-dns.md#a-local-address-on-linux-clients) |
| An internal DNS | a name in your zone, such as `ai.example.com`, with [two records](certificates-and-dns.md#the-names-to-publish) pointing at the box | nothing |
| Neither, across routers or a VPN | — | the box does not support it: a `.local` name does not cross a router, and a hosts file cannot name the generated apps |

Two boxes on one network need two different names:
[running two appliances](the-stack.md#running-two-appliances).

## 4 · Who will browsers trust?

| Your site has | Mode | People's machines need |
|---|---|---|
| Nothing in particular | [`internal`](certificates-and-dns.md#internal--the-default), the default — nothing to set | the box's root, imported once; [it can be pushed](certificates-and-dns.md#pushing-the-root-instead-of-visiting-every-desk) |
| Its own certificate authority | [`custom`](certificates-and-dns.md#custom--you-supply-the-certificate) | nothing |
| A public domain and outbound access | [`custom` with automatic renewal](certificates-and-dns.md#custom-with-automatic-renewal--nothing-to-install-anywhere) | nothing — not on an isolated site |
| A load balancer that holds your certificate | [`edge`](certificates-and-dns.md#edge--your-load-balancer-terminates-tls) | nothing |

Only `internal` needs no setting. The other three are written in
`/etc/understandtech/local.env` before the install, as each section shows.

## 5 · What does this machine do?

| It | Install with | Settings |
|---|---|---|
| Everything, with its own GPU | nothing more | — |
| Everything but inference, which runs on another machine | `--no-gpu`, or `--inference-from` when it is a compute node | [`VLLM_LLM_BASE_URL`](install.md#a-machine-that-serves-no-inference) names the machine that generates; `--inference-from` sets it with the node's key and root. Chats over documents need a GPU on this machine as well |
| Only inference, for a box that keeps the data | the compute overlay | [adding a second machine](certificates-and-dns.md#adding-a-second-machine) — read [what does not work yet](certificates-and-dns.md#what-does-not-work-yet) first |
| A test, beside a live install | `--dir … --no-autostart` | [installing beside something already running](install.md#installing-beside-something-already-running) |

## 6 · Where will backups go?

| They go | Set | Note |
|---|---|---|
| Nowhere but the box | nothing | a box that dies takes them with it |
| To a mounted disk — a NAS, a USB drive | [`BACKUP_FILES_DESTINATION`](configuration.md#backups) | `ut-install` refuses the box's own disk |
| Over the network — S3, SFTP | [`BACKUP_FILES_REPOSITORY`](configuration.md#sending-backups-off-the-machine) | SFTP needs a key you create first |

The install ends by showing two passwords, once. Losing the
backup password makes every backup unreadable.

## After the install

- A new version: [updating](update.md).
- A box that died: [restoring on another machine](restore.md#on-another-machine).
- A new address: [changing the address later](certificates-and-dns.md#changing-the-address-later).
- The App Builder, more workers, another engine: [configuring](configuration.md) —
  the App Builder only once the platform is running.
