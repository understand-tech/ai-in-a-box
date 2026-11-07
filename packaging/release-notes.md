**Install in one command.** `ut-get` downloads the package, refuses it unless
it is signed by UnderstandTech, installs it, then runs `ut-install`:

```bash
read -rs UT_LICENSE && export UT_LICENSE
curl -fsSLO -K <(printf 'user = "license:%s"\n' "$UT_LICENSE") \
    https://raw.pkg.keygen.sh/cdfe8998-3b6e-4f86-8f9f-c51a7cb642e0/856fd43a-b015-4e0f-9f45-f0c4353b69a8/@understandtech/VERSION/ut-get
sudo --preserve-env=UT_LICENSE bash ut-get --version VERSION --domain box.example.com
```

`read -rs` waits for the license key: paste it, then Enter.

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
