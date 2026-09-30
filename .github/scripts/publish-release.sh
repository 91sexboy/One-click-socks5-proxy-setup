#!/bin/sh
# Claim the distribution tag, fill its draft with the exact payload, publish it.
#
#   publish-release.sh claim     print the draft release id, creating tag or draft
#   publish-release.sh upload    RELEASE_ID: upload every absent payload member
#   publish-release.sh publish   RELEASE_ID: verify the draft, then publish it
#
# Moved out of the workflow YAML so a unit test can drive it against a fake gh.
# Only a draft is ever altered, every call after the claim addresses it by id,
# and a re-dispatch after a partial upload completes the same draft.
set -eu

: "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}" "${GITHUB_REF:?}" "${DISTRIBUTION_TAG:?}"
DIST=${DIST:-dist}
NOTES=${NOTES:-.github/releases/xray-v26.3.27-r1.md}
# Executables first, the checksum and provenance records last: an interrupted
# upload never leaves metadata describing an executable that is not there.
PAYLOAD='xray-v26.3.27-linux-amd64 xray-v26.3.27-linux-arm64 xray-v26.3.27-LICENSE.txt xray-v26.3.27-SHA256SUMS xray-v26.3.27-PROVENANCE.json'

refuse() {
    printf '%s\n' "$*" >&2
    exit 1
}

# The draft this run owns: still a draft, still on the distribution tag.
owned_draft() {
    _od=$(gh api "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID")
    test "$(printf '%s' "$_od" | jq -r .draft)" = true || refuse "refusing to alter a published release"
    test "$(printf '%s' "$_od" | jq -r .tag_name)" = "$DISTRIBUTION_TAG" || refuse "the claimed draft carries another tag"
    printf '%s' "$_od"
}

claim() {
    test "$GITHUB_REF" = refs/heads/xray-only || refuse "refusing a dispatch from $GITHUB_REF"
    claimed=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$DISTRIBUTION_TAG" 2>/dev/null |
        jq -r '.object.sha // empty' || true)
    release=''
    if [ -n "$claimed" ]; then
        test "$claimed" = "$GITHUB_SHA" || refuse "refusing tag owned by another commit: $claimed"
        # Every page: a draft beyond the first hundred releases is still ours.
        matches=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" |
            jq -s -c --arg tag "$DISTRIBUTION_TAG" '[.[][] | select(.tag_name==$tag)]')
        test "$(printf '%s' "$matches" | jq 'length')" -le 1 ||
            refuse "refusing: more than one release claims $DISTRIBUTION_TAG"
        release=$(printf '%s' "$matches" | jq -c 'if length == 1 then .[0] else empty end')
    else
        gh api --method POST "repos/$GITHUB_REPOSITORY/git/refs" \
            -f ref="refs/tags/$DISTRIBUTION_TAG" -f sha="$GITHUB_SHA" >/dev/null
    fi
    if [ -n "$release" ]; then
        test "$(printf '%s' "$release" | jq -r .draft)" = true || refuse "refusing to alter a published release"
        test "$(printf '%s' "$release" | jq -r .target_commitish)" = "$GITHUB_SHA" ||
            refuse "draft target differs from the dispatch commit"
    else
        # Created through the API rather than gh release create because the
        # response carries the new id: a just-created draft is not reliably in
        # the release listing yet, which is what stopped run 36292020667. The
        # run that prepared it is named here, not in the provenance record, so
        # the payload stays identical across a re-dispatch.
        run_url=${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/${GITHUB_RUN_ID:-local}
        release=$(jq -n --arg tag "$DISTRIBUTION_TAG" --arg target "$GITHUB_SHA" \
            --arg name "Xray v26.3.27 raw executables r1" \
            --rawfile body "$NOTES" --arg run "$run_url" \
            '{tag_name: $tag, target_commitish: $target, name: $name,
              body: ($body + "\nPrepared by workflow run " + $run + ".\n"),
              draft: true, prerelease: false}' |
            gh api --method POST "repos/$GITHUB_REPOSITORY/releases" --input -)
    fi
    claimed_id=$(printf '%s' "$release" | jq -r '.id // empty')
    case "$claimed_id" in
    '' | *[!0-9]*) refuse "cannot resolve the draft release id" ;;
    esac
    printf '%s\n' "$claimed_id"
}

upload() {
    : "${RELEASE_ID:?}"
    release=$(owned_draft)
    for name in $(printf '%s' "$release" | jq -r '.assets[].name'); do
        case " $PAYLOAD " in *" $name "*) ;; *) refuse "unexpected release assets: $name" ;; esac
    done
    for name in $PAYLOAD; do
        path=$DIST/$name
        test -f "$path" || refuse "missing payload member: $path"
        asset=$(printf '%s' "$release" | jq -c --arg name "$name" '.assets[] | select(.name==$name)')
        if [ -n "$asset" ]; then
            id=$(printf '%s' "$asset" | jq -r .id)
            if [ "$(printf '%s' "$asset" | jq -r .state)" != uploaded ]; then
                # An upload cut off mid-transfer leaves an incomplete asset under
                # the name. It holds no accepted bytes, so it is replaced, and
                # only while the release is still a draft.
                gh api --method DELETE "repos/$GITHUB_REPOSITORY/releases/assets/$id" >/dev/null
            else
                tmp=$(mktemp)
                gh api -H 'Accept: application/octet-stream' \
                    "repos/$GITHUB_REPOSITORY/releases/assets/$id" >"$tmp"
                cmp -s "$path" "$tmp" || { rm -f "$tmp"; refuse "refusing mismatched existing asset: $name"; }
                rm -f "$tmp"
                continue
            fi
        fi
        gh api --method POST -H 'Content-Type: application/octet-stream' \
            "https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID/assets?name=$name" \
            --input "$path" >/dev/null
    done
}

publish() {
    : "${RELEASE_ID:?}"
    # The tag must still stand where this run found it: publication may not
    # ride on a tag that moved underneath it.
    actual=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$DISTRIBUTION_TAG" | jq -r .object.sha)
    test "$actual" = "$GITHUB_SHA" || refuse "refusing: the tag moved from $GITHUB_SHA to $actual"
    release=$(owned_draft)
    test "$(printf '%s' "$release" | jq '.assets | length')" -eq 5 || refuse "the draft does not hold exactly the payload"
    # The published bytes are checked as downloaded: byte-identical to what this
    # run assembled, and consistent with the checksum file downloaded with them.
    fetched=$(mktemp -d)
    for name in $PAYLOAD; do
        id=$(printf '%s' "$release" | jq -r --arg name "$name" '.assets[] | select(.name==$name and .state=="uploaded") | .id')
        test -n "$id" || { rm -rf "$fetched"; refuse "the draft lacks an uploaded $name"; }
        gh api -H 'Accept: application/octet-stream' \
            "repos/$GITHUB_REPOSITORY/releases/assets/$id" >"$fetched/$name"
        cmp -s "$DIST/$name" "$fetched/$name" || { rm -rf "$fetched"; refuse "downloaded asset differs: $name"; }
    done
    (cd "$fetched" && sha256sum -c xray-v26.3.27-SHA256SUMS >/dev/null) ||
        { rm -rf "$fetched"; refuse "downloaded assets fail their checksum file"; }
    rm -rf "$fetched"
    gh api --method PATCH "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID" \
        -F draft=false -F prerelease=false >/dev/null
}

case "${1:-}" in
claim | upload | publish) "$1" ;;
*) refuse "usage: publish-release.sh claim|upload|publish" ;;
esac
