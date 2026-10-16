**Install in one command.** `ut-get` downloads the package, refuses it unless
it is signed by UnderstandTech, installs it, then runs `ut-install`:

```bash
curl -fsSLO https://github.com/understand-tech/ai-in-a-box/releases/download/vVERSION/ut-get
sudo bash ut-get --version VERSION --domain box.example.com
```

**Or check the package by hand before installing it.** `dpkg` ships with
`no-debsig`, so it installs a local file without verifying any signature:

```bash
./ut-verify understandtech_VERSION_all.deb
sudo apt-get install ./understandtech_VERSION_all.deb
sudo ut-install
```

`ut-verify` refuses a package that was altered, signed by another key, or not
signed at all. It needs `openssl` and no network.

`./ut-verify --fingerprint` prints the signing key's fingerprint, to compare
with the one published out of band.

## Where things go

| Path | Holds | On upgrade |
|---|---|---|
| `/usr/share/understandtech/` | the release | replaced |
| `/etc/understandtech/` | your settings and secrets | never touched |
| `/var/lib/understandtech/` | data | untouched, and kept even on purge |
