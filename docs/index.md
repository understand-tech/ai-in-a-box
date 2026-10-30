# AI in a Box documentation

This is the repository's own documentation: how to install, configure, operate
and change what is in here. For what AI in a Box is and why it runs at the
customer's site, see
[how AI in a Box works](https://github.com/understand-tech/internal-docs/blob/main/docs/on-prem-appliance/README.md).
For what people at the customer are told about using it, see the customer-facing
documentation; this repository does not repeat either.

**For the operator**, in the order you will need them:

| | When |
|---|---|
| [Architecture](architecture.md) | Where a request goes, what each network can reach, and which upstream repository each image comes from. |
| [Choosing how to install](choosing-how-to-install.md) | Before installing: six questions about your site, and the command or page each answer leads to. |
| [Installing](install.md) | A new machine. One command, safe to re-run. |
| [First-run configuration](first-run-configuration.md) | The first visit to a freshly installed box: models, sign-on, data sources. |
| [The stack](the-stack.md) | What runs, on which network, in which volume, and how to act on it. |
| [Configuring](configuration.md) | Changing the address, the ports, the backup schedule, the load. |
| [Licensing](license.md) | What a license governs, how it is activated and checked, and what happens when it ends. |
| [Certificates and DNS](certificates-and-dns.md) | Which names to publish, who terminates TLS, and what the local authority does. |
| [Updating](update.md) | A new version. What it adds to an existing `.env`, and what changes that you will notice. |
| [Backing up](backup.md) | What is backed up and what is not, how much a loss can cost, what the destination must provide, and who checks what. |
| [Restoring](restore.md) | The database, the customer's files, or the certificate authority — separately. |
| [Monitoring and the usage report](usage-report.md) | What is measured on the box, what reaches Fleet monitoring, and what it never holds. |
| [When it breaks](when-it-breaks.md) | A symptom, and which layer it belongs to. Start here when something is wrong. |
| [Decommissioning](decommissioning.md) | Taking a machine out of service. What removing the package does **not** remove. |

**For whoever builds or changes this repository**:

| | When |
|---|---|
| [Building and publishing a release](releasing.md) | How a tag becomes a signed package, a bill of materials and a GitHub release. |
| [CI and tests](ci-and-tests.md) | What runs on a pull request, a push, and a tag — and where to run it yourself. |

**For the people who use the platform**:
[using the platform](using-the-platform.md).
