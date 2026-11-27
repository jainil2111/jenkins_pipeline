#!/usr/bin/env bash
# Package cache for the build-wazuh job: reuse .deb files already built from the same commit(s).
#
#   pkg-cache.sh get <component> <key>             copy cached .deb(s) into $OUT; exit 0 = hit, 1 = miss
#   pkg-cache.sh put <component> <key> <files...>  store freshly built .deb(s) under <component>/<key>
#
# <key> is the commit SHA (or SHAs) the package was built from, so a new commit is always a miss.
# Settings (environment variables):
#   OUT             where "get" copies packages to (required for get)
#   PKG_CACHE       cache folder                         (default $HOME/pkg-cache)
#   PKG_CACHE_KEEP  versions kept per component          (default 2)
#   FORCE_REBUILD   "true" = always miss (e.g. after changing the build scripts themselves)
set -euo pipefail

CACHE="${PKG_CACHE:-$HOME/pkg-cache}"
KEEP="${PKG_CACHE_KEEP:-2}"
[ "$#" -ge 3 ] || { echo "usage: $0 get|put <component> <key> [files...]"; exit 2; }
cmd=$1 comp=$2 key=$3
shift 3
dir="$CACHE/$comp/$key"

case "$cmd" in
    get)
        if [ "${FORCE_REBUILD:-false}" = "true" ]; then
            echo "[cache] $comp: FORCE_REBUILD set - ignoring cache"
            exit 1
        fi
        if [ -f "$dir/.complete" ] && ls "$dir"/*.deb >/dev/null 2>&1; then
            # Hard link = instant, no extra disk space (same filesystem); fall back to a real copy
            cp -lv "$dir"/*.deb "$OUT/" 2>/dev/null || cp -v "$dir"/*.deb "$OUT/"
            touch "$dir"                       # mark as recently used
            echo "[cache] $comp: HIT ($key) - reused, build skipped"
            exit 0
        fi
        echo "[cache] $comp: miss ($key) - building"
        exit 1
        ;;
    put)
        [ "$#" -gt 0 ] || { echo "[cache] $comp: no files given, nothing stored"; exit 1; }
        mkdir -p "$CACHE/$comp"
        rm -rf "$dir.tmp" && mkdir -p "$dir.tmp"
        cp -v "$@" "$dir.tmp/"
        touch "$dir.tmp/.complete"             # only complete entries are ever reused
        rm -rf "$dir" && mv "$dir.tmp" "$dir"
        # Keep only the $KEEP most recently used versions of this component
        ls -1dt "$CACHE/$comp"/*/ 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf
        echo "[cache] $comp: stored ($key)"
        ;;
    *)
        echo "usage: $0 get|put <component> <key> [files...]"
        exit 2
        ;;
esac
