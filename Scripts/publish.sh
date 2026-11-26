#!/bin/bash
# Publishes a release in two stages. Run from the repository root, after
# `make release appcast site cask` for the version in Info.plist.
#
#   Scripts/publish.sh prepare   Tag vX.Y.Z, create a DRAFT GitHub release with the disk image and
#                                its notes, and stage the website and Homebrew commits locally.
#                                Nothing is visible to anyone else yet.
#   Scripts/publish.sh live      Publish the draft, then push the website and appcast (gh-pages)
#                                and the cask (homebrew-tap). In this order, Sparkle and Homebrew
#                                never point to a download that is not public yet.
set -euo pipefail

STAGE=${1:-}
REPO=gorkemblm/trove
TAP=gorkemblm/homebrew-tap
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
DMG="build/releases/Trove-$VERSION.dmg"
PAGES=build/publish/pages
TAPDIR=build/publish/tap

fail() { echo "publish: $*" >&2; exit 1; }

check_inputs() {
    [ -f "$DMG" ] || fail "$DMG is missing: run make release"
    [ -f build/site/appcast.xml ] || fail "build/site/appcast.xml is missing: run make appcast site"
    grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" build/site/appcast.xml \
        || fail "the appcast has no $VERSION: run make appcast site"
    [ -f build/Casks/trove.rb ] || fail "build/Casks/trove.rb is missing: run make cask"
    grep -q "version \"$VERSION\"" build/Casks/trove.rb || fail "the cask is not for $VERSION: run make cask"
    grep -q "^## $VERSION$" CHANGELOG.md || fail "CHANGELOG.md has no '## $VERSION' section"
}

# A fresh git folder holding exactly the given files, committed on top of the remote branch.
stage_folder() { # folder, remote url, branch, message
    local dir=$1 url=$2 branch=$3 message=$4
    git -C "$dir" init -q -b "$branch"
    git -C "$dir" remote add origin "$url"
    if git -C "$dir" fetch -q origin "$branch" 2>/dev/null; then
        git -C "$dir" reset -q --soft FETCH_HEAD
    fi
    git -C "$dir" add -A
    if git -C "$dir" diff --cached --quiet; then
        echo "  $branch: nothing changed"
    else
        git -C "$dir" commit -q -m "$message"
        echo "  $branch: committed, waiting for publish.sh live"
    fi
}

prepare() {
    check_inputs
    git diff --quiet && git diff --cached --quiet || fail "commit your changes first"

    echo "Tag $TAG"
    if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        git tag -a "$TAG" -m "Trove $VERSION"
    fi
    git push -q origin "$TAG"

    echo "Draft release $TAG"
    local notes="build/releases/Trove-$VERSION.md"
    python3 Scripts/release_notes.py "$VERSION" "$notes"
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        gh release upload "$TAG" "$DMG" --clobber -R "$REPO"
        gh release edit "$TAG" --title "Trove $VERSION" --notes-file "$notes" -R "$REPO" >/dev/null
    else
        gh release create "$TAG" "$DMG" --draft --verify-tag --title "Trove $VERSION" --notes-file "$notes" -R "$REPO" >/dev/null
    fi

    echo "Website and appcast (gh-pages)"
    rm -rf "$PAGES" && mkdir -p "$PAGES"
    cp -R build/site/. "$PAGES/"
    stage_folder "$PAGES" "https://github.com/$REPO.git" gh-pages "Trove $VERSION"

    echo "Homebrew cask ($TAP)"
    gh repo view "$TAP" >/dev/null 2>&1 \
        || gh repo create "$TAP" --private --description "Homebrew tap for Trove, an encrypted clipboard history for macOS" >/dev/null
    rm -rf "$TAPDIR" && mkdir -p "$TAPDIR/Casks"
    cp build/Casks/trove.rb "$TAPDIR/Casks/trove.rb"
    cp Homebrew/README.md "$TAPDIR/README.md"
    stage_folder "$TAPDIR" "https://github.com/$TAP.git" main "trove $VERSION"

    echo "Prepared $TAG. Check the draft: https://github.com/$REPO/releases"
}

live() {
    check_inputs
    [ -d "$PAGES/.git" ] && [ -d "$TAPDIR/.git" ] || fail "run publish.sh prepare first"

    echo "Publish release $TAG"
    gh release edit "$TAG" --draft=false --latest -R "$REPO" >/dev/null

    echo "Push website and appcast"
    git -C "$PAGES" push -q origin gh-pages
    # Pages needs a public repository on a free plan: then this waits for the next run.
    gh api "repos/$REPO/pages" >/dev/null 2>&1 \
        || gh api -X POST "repos/$REPO/pages" -f "source[branch]=gh-pages" -f "source[path]=/" >/dev/null 2>&1 \
        || echo "  Pages is not on yet (a private repository on a free plan?): run publish.sh live again once it is public"

    # Security reports reach the maintainers privately (SECURITY.md).
    gh api -X PUT "repos/$REPO/private-vulnerability-reporting" >/dev/null 2>&1 || true

    echo "Push Homebrew cask"
    git -C "$TAPDIR" push -q origin main

    echo "Live: https://github.com/$REPO/releases/tag/$TAG"
}

case "$STAGE" in
    prepare) prepare ;;
    live) live ;;
    *) fail "usage: Scripts/publish.sh prepare|live" ;;
esac
