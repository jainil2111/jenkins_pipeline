#!/usr/bin/env bash
# Builds the wazuh-dashboard .deb from YOUR forks.
# Used manually on the build VM and by the build-wazuh Jenkins job.
#
# Settings (environment variables, all optional):
#   GH             GitHub base URL of the forks   (default https://github.com/jainil2111)
#   DASHBOARD_REF  ref of wazuh-dashboard                     (default v4.14.10)
#   PLUGINS_REF    ref of wazuh-dashboard-plugins             (default v4.14.10)
#   SECURITY_REF   ref of wazuh-security-dashboards-plugin    (default v4.14.10)
#                  A ref can be a branch, tag or full commit SHA.
#   WORKDIR        where sources are fetched and built        (default $HOME/dashboard-build)
#   OUT            where the final .deb is copied             (default $WORKDIR/out)
#   REVISION       package revision                           (default 1)
#   CLEAN          1 = wipe untracked files incl. node_modules before building (slow, fully fresh)
#   SKIP_PLATFORM  1 = reuse an existing target/opensearch-dashboards-*.tar.gz (skip step 3a, saves ~1h)
set -euo pipefail

GH="${GH:-https://github.com/jainil2111}"
DASHBOARD_REF="${DASHBOARD_REF:-v4.14.10}"
PLUGINS_REF="${PLUGINS_REF:-v4.14.10}"
SECURITY_REF="${SECURITY_REF:-v4.14.10}"
WORKDIR="${WORKDIR:-$HOME/dashboard-build}"
OUT="${OUT:-$WORKDIR/out}"
REVISION="${REVISION:-1}"
CLEAN="${CLEAN:-0}"
SKIP_PLATFORM="${SKIP_PLATFORM:-0}"

DASH="$WORKDIR/wazuh-dashboard"
PLUGINS_SRC="$WORKDIR/wazuh-dashboard-plugins"
SECURITY_SRC="$WORKDIR/wazuh-security-dashboards-plugin"
PKG="$WORKDIR/packages"
YARN_CACHE="$HOME/.cache/yarn-dashboard"

step() { echo; echo "=== $* ==="; }

# fetch <repo-name> <ref> <dir>: shallow-fetch exactly one ref into <dir>
fetch() {
    local repo=$1 ref=$2 dir=$3
    mkdir -p "$dir"
    # Check for $dir/.git itself: "git rev-parse" would also find a PARENT repo (e.g. the Jenkins workspace)
    [ -d "$dir/.git" ] || git -C "$dir" init --quiet
    git -C "$dir" remote remove origin 2>/dev/null || true
    git -C "$dir" remote add origin "$GH/$repo.git"
    git -C "$dir" fetch --quiet --depth 1 origin "$ref"
    git -C "$dir" checkout --quiet --force FETCH_HEAD
    if [ "$CLEAN" = "1" ]; then git -C "$dir" clean -fdxq; fi
    echo "$repo @ $(git -C "$dir" rev-parse --short HEAD)  (ref: $ref)"
}

step "1. Fetch sources from $GH"
mkdir -p "$WORKDIR" "$OUT" "$YARN_CACHE"
fetch wazuh-dashboard                  "$DASHBOARD_REF" "$DASH"
fetch wazuh-dashboard-plugins          "$PLUGINS_REF"   "$PLUGINS_SRC"
fetch wazuh-security-dashboards-plugin "$SECURITY_REF"  "$SECURITY_SRC"

step "2. Remove plugins from previous runs (they must NOT be present during bootstrap)"
if [ "$SKIP_PLATFORM" = "1" ] && ls "$DASH"/target/opensearch-dashboards-*-linux-x64.tar.gz >/dev/null 2>&1; then
    echo "SKIP_PLATFORM=1: reusing $(ls "$DASH"/target/opensearch-dashboards-*-linux-x64.tar.gz)"
else
    SKIP_PLATFORM=0
    rm -rf "$DASH/target"
fi
for p in main wazuh-core wazuh-check-updates wazuh-security-dashboards-plugin; do
    rm -rf "$DASH/plugins/$p"
done
NODE="$(cat "$DASH/.nvmrc")"
OSD_VERSION="$(grep -m1 '"version"' "$DASH/package.json" | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
echo "OpenSearch Dashboards version: $OSD_VERSION"
echo "Node $NODE (plugins repo .nvmrc: $(cat "$PLUGINS_SRC/.nvmrc" 2>/dev/null || echo n/a))"

# run_node "<commands>": run commands in the node container, in wazuh-dashboard.
# Runs as YOUR user (not root): OpenSearch Dashboards refuses to build as root.
run_node() {
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        -v "$DASH:/w" -v "$YARN_CACHE:/yarn-cache" \
        -w /w \
        -e HOME=/tmp/home \
        -e YARN_CACHE_FOLDER=/yarn-cache \
        -e YARN_NETWORK_TIMEOUT=600000 \
        -e CYPRESS_INSTALL_BINARY=0 \
        -e PUPPETEER_SKIP_DOWNLOAD=true \
        -e PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
        -e CHROMEDRIVER_SKIP_DOWNLOAD=true \
        -e GECKODRIVER_SKIP_DOWNLOAD=true \
        -e NODE_OPTIONS=--max-old-space-size=6144 \
        -e OPENSEARCH_DASHBOARDS_VERSION="$OSD_VERSION" \
        "node:$NODE" bash -euxc "
            mkdir -p /tmp/home
            npm config set prefix /tmp/home/.npm-global
            npm i -g yarn@1.22.22 >/dev/null
            export PATH=/tmp/home/.npm-global/bin:\$PATH
            yarn --version
            git config --global --add safe.directory '*'
            $1
        "
}

step "3a. Bootstrap + build the dashboard platform in node:$NODE (longest step)"
if [ "$SKIP_PLATFORM" = "1" ]; then
    echo "skipped (SKIP_PLATFORM=1)"
else
    run_node "yarn osd bootstrap && yarn build-platform --linux --skip-os-packages --release"
fi

step "3b. Place your plugins inside wazuh-dashboard/plugins"
for p in main wazuh-core wazuh-check-updates; do
    cp -a "$PLUGINS_SRC/plugins/$p" "$DASH/plugins/$p"
done
cp -a "$SECURITY_SRC" "$DASH/plugins/wazuh-security-dashboards-plugin"

step "3c. Build the security plugin and the Wazuh plugins"
run_node "(cd plugins/wazuh-security-dashboards-plugin && yarn && yarn build)
          for p in main wazuh-core wazuh-check-updates; do (cd plugins/\$p && yarn && yarn build); done"

step "4. Create the 3 zip packages"
for z in "$DASH"/target/opensearch-dashboards-*-linux-x64.tar.gz \
         "$DASH"/plugins/wazuh-security-dashboards-plugin/build/security-dashboards-*.zip \
         "$DASH"/plugins/main/build/wazuh-*.zip \
         "$DASH"/plugins/wazuh-core/build/wazuhCore-*.zip \
         "$DASH"/plugins/wazuh-check-updates/build/wazuhCheckUpdates-*.zip; do
    [ -f "$z" ] || { echo "MISSING build output: $z"; exit 1; }
done
rm -rf "$PKG" && mkdir -p "$PKG" && cd "$PKG"
zip -q -r -j dashboard-package.zip "$DASH"/target/opensearch-dashboards-*-linux-x64.tar.gz
zip -q -r -j security-package.zip  "$DASH"/plugins/wazuh-security-dashboards-plugin/build/security-dashboards-*.zip
zip -q -r -j wazuh-package.zip     "$DASH"/plugins/wazuh-check-updates/build/wazuhCheckUpdates-*.zip \
                                   "$DASH"/plugins/main/build/wazuh-*.zip \
                                   "$DASH"/plugins/wazuh-core/build/wazuhCore-*.zip
ls -lh

step "5. Version stamp from your 3 commits (dashboard-plugins-security)"
SHA="$(git -C "$DASH" rev-parse --short HEAD)-$(git -C "$PLUGINS_SRC" rev-parse --short HEAD)-$(git -C "$SECURITY_SRC" rev-parse --short HEAD)"
echo "$SHA"

step "6. Build the .deb (build-packages.sh, runs its own containers)"
cd "$DASH/dev-tools/build-packages"
# previous output may be root-owned (written by containers); remove it via a container if needed
rm -rf output 2>/dev/null || docker run --rm -v "$PWD:/x" debian:12-slim rm -rf /x/output
./build-packages.sh --commit-sha "$SHA" -r "$REVISION" --deb \
    -a "file://$PKG/wazuh-package.zip" \
    -s "file://$PKG/security-package.zip" \
    -b "file://$PKG/dashboard-package.zip"

step "7. Copy result to $OUT"
find output -name '*.deb' -exec cp -v {} "$OUT/" \;
ls -lh "$OUT"
