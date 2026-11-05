#!/usr/bin/env bash
# Publish a folio release:
#   1. build the signed APT index (gh-pages branch) with the new .debs
#   2. create the GitHub release with the artifacts and a signed SHA256SUMS
#   3. push the APT index
#
# Usage: ./publish.sh <version> <artifact-dir>
#   <version> is the Debian version, e.g. 0.1.0~alpha1 (tag: v0.1.0-alpha.1).
#   Versions containing ~alpha/~beta/~rc go to the pre-release suite "alpha" and are
#   marked as GitHub pre-releases; plain versions go to "stable".
#   <artifact-dir> must contain the output of `cargo xtask dist release`:
#     folio_<v>_amd64.deb, folio-fonts-extra_<v>_all.deb,
#     folio-<v>-x86_64-linux.tar.zst, folio-fonts-extra-<v>.tar.zst,
#     folio-<v>-source.tar.zst
#   Release notes: notes/<version>.md, if present, is appended to the generic notes.
#
# Signing uses YOUR local gpg key (the private key never leaves this machine).
#
# Dry run (no GitHub, no push; for testing with a throwaway key):
#   DRY_RUN=1 FOLIO_APT_KEY=<fpr> GNUPGHOME=<tmp> FOLIO_APT_SITE=<dir> ./publish.sh <v> <dir>
#   builds the site in FOLIO_APT_SITE (kept; existing content is updated like gh-pages
#   would be), with folio-archive-keyring.{gpg,asc} exported from FOLIO_APT_KEY.
set -euo pipefail

SIGNING_KEY="${FOLIO_APT_KEY:-B894610BF670F51C24A645CB5480C67127C874E8}"
KEEP_VERSIONS="${KEEP_VERSIONS:-3}"   # older .debs are pruned from the APT pool (they stay in Releases)
REPO="${FOLIO_APT_REPO:-Flecart/folio-apt}"
DRY_RUN="${DRY_RUN:-0}"

v="${1:?usage: publish.sh <version> <artifact-dir>}"
art="$(cd "${2:?usage: publish.sh <version> <artifact-dir>}" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
# Debian 0.1.0~alpha1  <->  tag/semver 0.1.0-alpha.1
semver="$(echo "$v" | sed -E 's/~(alpha|beta|rc)([0-9]+)/-\1.\2/')"
tag="v${semver%%+*}"
if [[ $v == *~* ]]; then suite=alpha; pre=(--prerelease); else suite=stable; pre=(); fi
pages="https://$(echo "${REPO%%/*}" | tr 'A-Z' 'a-z').github.io/${REPO#*/}"

if [[ $v == *+* ]] && [[ $DRY_RUN != 1 ]]; then
  echo "refusing to publish $v: a +dirty/+build version is a local test build (DRY_RUN=1 only)" >&2
  exit 1
fi

need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
tools=(gpg git apt-ftparchive dpkg dpkg-deb sha256sum gzip)
[[ $DRY_RUN == 1 ]] || tools+=(gh)
for t in "${tools[@]}"; do need "$t"; done

files=(
  "folio_${v}_amd64.deb" "folio-fonts-extra_${v}_all.deb"
  "folio-${v}-x86_64-linux.tar.zst" "folio-fonts-extra-${v}.tar.zst"
  "folio-${v}-source.tar.zst"
)
for f in "${files[@]}"; do [[ -f "$art/$f" ]] || { echo "missing artifact: $art/$f" >&2; exit 1; }; done
# GPL: never publish binaries without the corresponding source
[[ -s "$art/folio-${v}-source.tar.zst" ]] || { echo "source tarball empty" >&2; exit 1; }
for d in "folio_${v}_amd64.deb" "folio-fonts-extra_${v}_all.deb"; do
  dpkg-deb -f "$art/$d" Version | grep -qxF "$v" || { echo "$d: version != $v" >&2; exit 1; }
done

gpg --list-secret-keys "$SIGNING_KEY" >/dev/null 2>&1 \
  || { echo "secret key $SIGNING_KEY not available in your gpg keyring" >&2; exit 1; }
sign() { gpg --batch --yes --local-user "$SIGNING_KEY" "$@"; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# The keyring users install must hold the key the index is signed with.
if [[ $DRY_RUN == 1 ]]; then
  gpg --export "$SIGNING_KEY" > "$work/folio-archive-keyring.gpg"
  gpg --armor --export "$SIGNING_KEY" > "$work/folio-archive-keyring.asc"
  keyring="$work"
else
  keyring="$here"
fi
fpr="$(gpg --with-colons --fingerprint "$SIGNING_KEY" | awk -F: '/^fpr/ {print $10; exit}')"
gpg --show-keys --with-colons "$keyring/folio-archive-keyring.gpg" | grep -q "^fpr:.*:$fpr:" \
  || { echo "$keyring/folio-archive-keyring.gpg does not contain the signing key $fpr" >&2; exit 1; }

# --- 1. APT index (built locally first, so a failure leaves nothing half-published) --
if [[ $DRY_RUN == 1 ]]; then
  site="${FOLIO_APT_SITE:?DRY_RUN=1 needs FOLIO_APT_SITE=<local site dir>}"
  mkdir -p "$site"; site="$(cd "$site" && pwd)"
else
  site="$work/site"
  if ! git clone -q --branch gh-pages "https://github.com/$REPO.git" "$site" 2>/dev/null; then
    # first release: start the gh-pages branch
    git clone -q "https://github.com/$REPO.git" "$site"
    git -C "$site" checkout -q --orphan gh-pages
    git -C "$site" rm -rqf . 2>/dev/null || true
    git -C "$site" clean -fdxq
  fi
fi
mkdir -p "$site/pool/$suite/f/folio" "$site/pool/$suite/f/folio-fonts-extra"
cp "$art/folio_${v}_amd64.deb" "$site/pool/$suite/f/folio/"
cp "$art/folio-fonts-extra_${v}_all.deb" "$site/pool/$suite/f/folio-fonts-extra/"

# prune: keep the newest $KEEP_VERSIONS of each package, in dpkg's version order
for d in "$site"/pool/*/f/*/; do
  ordered=()   # "version path", ascending
  for f in "$d"*.deb; do
    [[ -e $f ]] || continue
    ver="$(dpkg-deb -f "$f" Version)"; i=${#ordered[@]}
    while ((i > 0)) && dpkg --compare-versions "$ver" lt "${ordered[i-1]%% *}"; do i=$((i-1)); done
    ordered=("${ordered[@]:0:i}" "$ver $f" "${ordered[@]:i}")
  done
  for ((i = 0; i < ${#ordered[@]} - KEEP_VERSIONS; i++)); do rm -f "${ordered[i]#* }"; done
done

cp "$keyring/folio-archive-keyring.gpg" "$keyring/folio-archive-keyring.asc" "$site/"
cp "$here/README.md" "$site/"
touch "$site/.nojekyll"

(
  cd "$site"
  rm -rf "dists/$suite"
  for arch in amd64 all; do
    d="dists/$suite/main/binary-$arch"; mkdir -p "$d"
    # binary-amd64 also lists arch:all packages (apt expects them there too)
    if [[ $arch == amd64 ]]; then apt-ftparchive packages "pool/$suite" > "$d/Packages"
    else apt-ftparchive packages "pool/$suite" | awk -v RS= -v ORS='\n\n' '/\nArchitecture: all\n/' > "$d/Packages"; fi
    gzip -9nkf "$d/Packages"
  done
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="folio" \
    -o APT::FTPArchive::Release::Label="folio" \
    -o APT::FTPArchive::Release::Suite="$suite" \
    -o APT::FTPArchive::Release::Codename="$suite" \
    -o APT::FTPArchive::Release::Architectures="amd64 all" \
    -o APT::FTPArchive::Release::Components="main" \
    -o APT::FTPArchive::Release::Description="folio LaTeX compiler" \
    release "dists/$suite" > "$work/Release"
  mv "$work/Release" "dists/$suite/Release"
  sign --clearsign --output "dists/$suite/InRelease" "dists/$suite/Release"
  sign --armor --detach-sign --output "dists/$suite/Release.gpg" "dists/$suite/Release"
  gpg --verify "dists/$suite/InRelease" 2>/dev/null || { echo "InRelease does not verify" >&2; exit 1; }
)

# --- 2. GitHub release ---------------------------------------------------------------
# GitHub renames asset files with characters such as `~`, which would break
# SHA256SUMS; the assets are named with the tag's version (folio_0.1.0-alpha.1_amd64.deb).
assets="$work/assets"; mkdir -p "$assets"
names=()
for f in "${files[@]}"; do n="${f//"$v"/"${semver}"}"; cp "$art/$f" "$assets/$n"; names+=("$n"); done
( cd "$assets" && sha256sum "${names[@]}" > SHA256SUMS )
sign --armor --detach-sign --output "$assets/SHA256SUMS.asc" "$assets/SHA256SUMS"
upload=("${names[@]/#/$assets/}" "$assets/SHA256SUMS" "$assets/SHA256SUMS.asc")

notes="folio ${tag#v}$([[ $suite == alpha ]] && echo ' (ALPHA: expect rough edges; please report issues)').

Install from the APT repository (see the README: $pages) or download the .deb below.

Complete corresponding source: folio-${semver}-source.tar.zst (GPL-2.0-or-later): the folio tree and every Rust dependency, vendored; it builds offline (\`cargo build --release --offline\`).

Verify downloads: \`gpg --verify SHA256SUMS.asc SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS\`"
[[ -f "$here/notes/$v.md" ]] && notes="$notes"$'\n\n'"$(cat "$here/notes/$v.md")"

if [[ $DRY_RUN == 1 ]]; then
  rm -rf "$site.release"; cp -r "$assets" "$site.release"
  echo "DRY RUN: would create GitHub release $tag on $REPO ${pre[*]:-} with:"
  printf '  %s\n' "${upload[@]##*/}"
  echo "--- notes ---"; echo "$notes"; echo "-------------"
  echo "DRY RUN: APT site ($suite) in $site; release assets in $site.release"
  exit 0
fi

if gh release view "$tag" -R "$REPO" >/dev/null 2>&1; then
  echo "release $tag already exists; uploading (clobber) assets"
  gh release upload "$tag" -R "$REPO" --clobber "${upload[@]}"
else
  gh release create "$tag" -R "$REPO" "${pre[@]}" --title "folio ${tag#v}" --notes "$notes" "${upload[@]}"
fi

# --- 3. push the APT index -------------------------------------------------------------
cd "$site"
git add -A
if git diff --cached --quiet; then
  echo "APT index unchanged"
else
  git -c user.name="$(git -C "$here" config user.name)" -c user.email="$(git -C "$here" config user.email)" \
    commit -qm "apt($suite): folio $v"
  git push -q origin gh-pages
fi
echo "published folio $v ($suite): https://github.com/$REPO/releases/tag/$tag and $pages/"
