# folio APT repository

> **Alpha.** folio is in alpha: compiles real papers, but expect rough edges and breaking changes between alpha releases. Packages are published to the `alpha` suite and marked as GitHub pre-releases. A `stable` suite will follow.

Debian/Ubuntu packages for **folio**. folio is a fast LaTeX-document compiler written in Rust that needs no TeX Live installation.

| Package | What it contains |
|---|---|
| `folio` | The compiler, plus its own data tree: Computer Modern, Latin Modern, EC/cm-super (common shapes), URW Times/Helvetica/Courier, AMS fonts, hyphenation for 12 languages, and BibTeX base and natbib styles. About 30 MB download and 41 MB installed. |
| `folio-fonts-extra` | Optional. Rare cm-super shapes, every Latin Modern encoding, and Palatino, New Century, Bookman, Avant Garde and Zapf Chancery. |

The packages run on **amd64** systems with glibc ≥ 2.36: Debian 12 (bookworm) or later, and Ubuntu 22.04 or later.

## Install

```sh
# 1. Trust the signing key. Fingerprint: B894 610B F670 F51C 24A6  45CB 5480 C671 27C8 74E8
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://flecart.github.io/folio-apt/folio-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/folio-archive-keyring.gpg > /dev/null

# 2. Add the repository
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/folio-archive-keyring.gpg] https://flecart.github.io/folio-apt alpha main" \
  | sudo tee /etc/apt/sources.list.d/folio.list

# 3. Install
sudo apt update
sudo apt install folio            # optional: folio-fonts-extra
```

Check the key's fingerprint after step 1:

```sh
gpg --show-keys /etc/apt/keyrings/folio-archive-keyring.gpg
```

It must show `B894610BF670F51C24A645CB5480C67127C874E8`.

Updates then arrive through `sudo apt upgrade`.

### Without the repository

Download the `.deb` from the [Releases](https://github.com/Flecart/folio-apt/releases) page and install it:

```sh
sudo apt install ./folio_0.1.0~alpha1_amd64.deb   # version from the release page
```

Every release also includes `SHA256SUMS` and its signature, `SHA256SUMS.asc`. To verify a download:

```sh
gpg --verify SHA256SUMS.asc SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS
```

### Other Linux distributions

Unpack `folio-<version>-x86_64-linux.tar.zst` anywhere. The binary finds its data tree next to itself.

## Use

```sh
folio paper.tex          # writes paper.pdf next to it
folio doctor             # shows which data trees and fonts folio uses
```

When a document needs a package or font that isn't in the bundle, folio reports the missing file by name. If TeX Live is also installed, folio uses it for those files automatically. `--no-system-texmf` turns that off.

## Uninstall

```sh
sudo apt remove folio folio-fonts-extra
sudo rm /etc/apt/sources.list.d/folio.list /etc/apt/keyrings/folio-archive-keyring.gpg
```

## Source code and licences

folio is free software under **GPL-2.0-or-later**. Every release publishes the complete corresponding source as `folio-<version>-source.tar.zst`. It contains folio and every vendored Rust dependency, and builds offline. The bundled TeX data files keep their own licences: LPPL, GPL, OFL, GUST, Knuth and others. These are listed in `/usr/share/doc/folio/copyright`.

---

*Versioning:* Debian versions use `~alpha`/`~rc` (e.g. `0.1.0~alpha1`, tag `v0.1.0-alpha.1`) so that the final `0.1.0` sorts after every pre-release.

*Maintainer notes:* this repository holds only release artifacts and the APT index (on the `gh-pages` branch). The packages are built from the folio sources by `cargo xtask dist release`. Run `./publish.sh 0.1.0~alpha1 <artifact-dir>` to create a GitHub release and update the signed APT index. Signing uses the maintainer's local GPG key; the key is never stored in CI.
