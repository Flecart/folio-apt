#!/usr/bin/env bash
# Publish a folio release:
#   1. create the GitHub release with the artifacts and signed SHA256SUMS
#   2. rebuild the signed APT index on the gh-pages branch and push it
#
# Usage: ./publish.sh <version> <artifact-dir>
#   <version> is the Debian version, e.g. 0.1.0~alpha1 (tag: v0.1.0-alpha.1).
#   Versions containing ~alpha/~beta/~rc go to the pre-release suite "alpha" and are
#   marked as GitHub pre-releases; plain versions go to "stable".
#   <artifact-dir> must contain the output of `cargo xtask dist release`:
#     folio_<v>_amd64.deb, folio-fonts-extra_<v>_all.deb,
#     folio-<v>-x86_64-linux.tar.zst, folio-fonts-extra-<v>.tar.zst,
#     folio-<v>-source.tar.zst
#
# Signing uses YOUR local gpg key (the private key never leaves this machine):
SIGNING_KEY="${FOLIO_APT_KEY:-B894610BF670F51C24A645CB5480C67127C874E8}"
KEEP_VERSIONS="${KEEP_VERSIONS:-3}"   # older .debs are pruned from the APT pool (they stay in Releases)
REPO="${FOLIO_APT_REPO:-Flecart/folio-apt}"
set -euo pipefail

v="${1:?usage: publish.sh <version> <artifact-dir>}"
art="$(cd "${2:?usage: publish.sh <version> <artifact-dir>}" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
# Debian 0.1.0~alpha1  <->  tag/semver 0.1.0-alpha.1
tag="v$(echo "$v" | sed -E 's/~(alpha|beta|rc)([0-9]+)/-\1.\2/')"
if [[ $v == *~* ]]; then suite=alpha; pre=(--prerelease); else suite=stable; pre=(); fi

need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
for t in gh gpg git apt-ftparchive dpkg-deb sha256sum; do need "$t"; done

files=(
  "folio_${v}_amd64.deb" "folio-fonts-extra_${v}_all.deb"
  "folio-${v}-x86_64-linux.tar.zst" "folio-fonts-extra-${v}.tar.zst"
  "folio-${v}-source.tar.zst"
)
for f in "${files[@]}"; do [[ -f "$art/$f" ]] || { echo "missing artifact: $art/$f" >&2; exit 1; }; done
# GPL: never publish binaries without the corresponding source
[[ -s "$art/folio-${v}-source.tar.zst" ]] || { echo "source tarball empty" >&2; exit 1; }
dpkg-deb -f "$art/folio_${v}_amd64.deb" Version | grep -qx "$v" || { echo ".deb version != $v" >&2; exit 1; }

gpg --list-secret-keys "$SIGNING_KEY" >/dev/null 2>&1 \
  || { echo "secret key $SIGNING_KEY not available in your gpg keyring" >&2; exit 1; }

# --- 1. GitHub release -------------------------------------------------------
( cd "$art" && sha256sum "${files[@]}" > SHA256SUMS )
rm -f "$art/SHA256SUMS.asc"
gpg --local-user "$SIGNING_KEY" --armor --detach-sign --output "$art/SHA256SUMS.asc" "$art/SHA256SUMS"

if gh release view "$tag" -R "$REPO" >/dev/null 2>&1; then
  echo "release $tag already exists; uploading (clobber) assets"
  gh release upload "$tag" -R "$REPO" --clobber "${files[@]/#/$art/}" "$art/SHA256SUMS" "$art/SHA256SUMS.asc"
else
  gh release create "$tag" -R "$REPO" "${pre[@]}" --title "folio ${tag#v}" \
    --notes "folio ${tag#v}$([[ $suite == alpha ]] && echo ' (ALPHA: expect rough edges; report issues)'). Install via the APT repository (see README) or download the .deb below. Complete corresponding source: folio-${v}-source.tar.zst (GPL-2.0-or-later). Verify: gpg --verify SHA256SUMS.asc SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS" \
    "${files[@]/#/$art/}" "$art/SHA256SUMS" "$art/SHA256SUMS.asc"
fi

# --- 2. APT index on gh-pages -----------------------------------------------
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
git clone -q --branch gh-pages "https://github.com/$REPO.git" "$work/site" 2>/dev/null \
  || { git clone -q "https://github.com/$REPO.git" "$work/site"; git -C "$work/site" checkout -q --orphan gh-pages; git -C "$work/site" rm -rqf . || true; }
site="$work/site"
mkdir -p "$site/pool/$suite/f/folio" "$site/pool/$suite/f/folio-fonts-extra"
cp "$art/folio_${v}_amd64.deb" "$site/pool/$suite/f/folio/"
cp "$art/folio-fonts-extra_${v}_all.deb" "$site/pool/$suite/f/folio-fonts-extra/"

# prune: keep the newest $KEEP_VERSIONS of each package (version-sorted)
for d in "$site"/pool/*/f/*/; do
  ls "$d"*.deb 2>/dev/null | sort -V | head -n -"$KEEP_VERSIONS" | xargs -r rm -f
done

cp "$here/folio-archive-keyring.gpg" "$here/folio-archive-keyring.asc" "$here/README.md" "$site/"
touch "$site/.nojekyll"

cd "$site"
rm -rf "dists/$suite"
for arch in amd64 all; do
  d="dists/$suite/main/binary-$arch"; mkdir -p "$d"
  # binary-amd64 also lists arch:all packages (apt expects them there too)
  if [[ $arch == amd64 ]]; then apt-ftparchive packages "pool/$suite" > "$d/Packages"
  else apt-ftparchive packages "pool/$suite" | awk -v RS= -v ORS='\n\n' '/\nArchitecture: all\n/' > "$d/Packages"; fi
  gzip -9nk "$d/Packages"
done
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="folio" \
  -o APT::FTPArchive::Release::Label="folio" \
  -o APT::FTPArchive::Release::Suite="$suite" \
  -o APT::FTPArchive::Release::Codename="$suite" \
  -o APT::FTPArchive::Release::Architectures="amd64 all" \
  -o APT::FTPArchive::Release::Components="main" \
  -o APT::FTPArchive::Release::Description="folio LaTeX compiler" \
  release "dists/$suite" > "dists/$suite/Release"
gpg --local-user "$SIGNING_KEY" --clearsign --output "dists/$suite/InRelease" "dists/$suite/Release"
gpg --local-user "$SIGNING_KEY" --armor --detach-sign --output "dists/$suite/Release.gpg" "dists/$suite/Release"

git add -A
git -c user.name="$(git -C "$here" config user.name)" -c user.email="$(git -C "$here" config user.email)" \
  commit -qm "apt($suite): folio $v"
git push -q origin gh-pages
echo "published folio $v ($suite): https://github.com/$REPO/releases/tag/$tag and https://${REPO%%/*}.github.io/${REPO#*/}/" | tr 'A-Z' 'a-z'
