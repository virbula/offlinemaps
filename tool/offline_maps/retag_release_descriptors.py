#!/usr/bin/env python3
"""Rewrites the release tag embedded in a release's descriptor URLs.

Descriptors carry absolute download URLs, so the tag they were published under
is baked into every one. Renaming a release therefore leaves each descriptor
pointing at a tag that no longer resolves, and every part download 404s while
the descriptor still looks perfectly well formed -- the failure surfaces on a
user's device rather than in any publishing check.

This is the second half of a rename: move the release, then repoint the
descriptors it contains. The parts themselves need no change, since only the
tag in the URL moved.

Checksums are deliberately untouched. A descriptor's sha256 covers the asset
bytes, not the URL used to fetch them, so repointing a URL neither invalidates
nor requires recomputing them.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile


def run(args, check=True):
    result = subprocess.run(['gh'] + args, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f'gh {" ".join(args)} failed: {result.stderr[-500:]}')
    return result.stdout


def _releases_via_rest(repository):
    out = run(['api', f'repos/{repository}/releases', '--paginate',
               '--jq', '.[]|{id,tag_name}'], check=False)
    found = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        found[record['tag_name']] = record['id']
    return found


def _releases_via_graphql(repository):
    """Second opinion, because the REST list is not always trustworthy.

    Observed returning an empty array for a repository holding ten releases,
    while fetching any one of them by id or tag still worked. A tool that
    resolves ids by listing then concludes the release does not exist and either
    fails or, worse, renames nothing and reports success.
    """
    owner, name = repository.split('/', 1)
    query = ('{repository(owner:"%s",name:"%s"){releases(first:100)'
             '{nodes{databaseId tagName}}}}' % (owner, name))
    out = run(['api', 'graphql', '-f', f'query={query}', '--jq',
               '.data.repository.releases.nodes[]|{id:.databaseId,'
               'tag_name:.tagName}'], check=False)
    found = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        found[record['tag_name']] = record['id']
    return found


def release_id(repository, tag):
    """Finds a release by tag, including drafts.

    A draft has no git tag behind it, so releases/tags/<tag> returns 404 even
    though the release exists and is addressable by id. Renaming happens while
    the replacement is still a draft, which is exactly when this runs.

    Tries REST first and falls back to GraphQL, which disagree in practice: the
    REST list came back empty for a repository that plainly had ten releases.
    Reporting "no release tagged X" when X exists is the failure this avoids.
    """
    for lookup in (_releases_via_rest, _releases_via_graphql):
        found = lookup(repository)
        if tag in found:
            return found[tag]
        if found:
            # The listing worked and the tag genuinely is not in it.
            raise SystemExit(
                f'no release tagged {tag} (drafts included); '
                f'{len(found)} releases visible')
    raise SystemExit(
        f'could not list the releases of {repository} through REST or GraphQL, '
        f'so {tag} cannot be resolved. Both returned nothing, which means the '
        'listing is broken rather than the release being absent.')


def descriptor_names(repository, tag):
    out = run(['api', f'repos/{repository}/releases/{release_id(repository, tag)}'
               '/assets?per_page=100', '--paginate',
               '--jq', '.[]|select(.name|endswith("descriptor.json")).name'])
    return [line for line in out.splitlines() if line.strip()]


def retag(repository, tag, old_tag, new_tag, dry_run):
    names = descriptor_names(repository, tag)
    if not names:
        raise SystemExit(f'{tag} carries no descriptors')
    old = f'/releases/download/{old_tag}/'
    new = f'/releases/download/{new_tag}/'
    changed = skipped = 0
    with tempfile.TemporaryDirectory() as work:
        for name in names:
            run(['release', 'download', tag, '-R', repository,
                 '--pattern', name, '--dir', work, '--clobber'])
            path = os.path.join(work, name)
            with open(path, encoding='utf-8') as handle:
                text = handle.read()
            if old not in text:
                skipped += 1
                os.remove(path)
                continue
            updated = text.replace(old, new)
            # Parse after rewriting, so a substitution that corrupted the JSON
            # is caught here rather than on a device.
            json.loads(updated)
            with open(path, 'w', encoding='utf-8') as handle:
                handle.write(updated)
            if not dry_run:
                run(['release', 'upload', tag, path, '-R', repository, '--clobber'])
            changed += 1
            os.remove(path)
    verb = 'would repoint' if dry_run else 'repointed'
    print(f'  {verb} {changed} descriptor(s); {skipped} already correct')
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', default='virbula/offlinemaps')
    parser.add_argument('--tag', required=True,
                        help='release holding the descriptors, after any rename')
    parser.add_argument('--old-tag', required=True,
                        help='tag currently embedded in the URLs')
    parser.add_argument('--new-tag', required=True,
                        help='tag the URLs should point at')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    retag(args.repository, args.tag, args.old_tag, args.new_tag, args.dry_run)
    return 0


if __name__ == '__main__':
    sys.exit(main())
