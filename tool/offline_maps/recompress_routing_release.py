#!/usr/bin/env python3
"""Republish routing graphs gzipped, without rebuilding any of them.

A Valhalla graph is raw packed structs with no internal compression, and
measured 37% on the real 31 GB Europe archive. Shipping them uncompressed
costs nearly three times the bytes for no benefit. PMTiles deliberately does
not get this treatment: it already gzips every tile, so it measured 99%, and
whole-archive compression would break the byte-range reads the renderer needs.

This recompresses existing published artifacts rather than reprocessing.
Building a continent graph takes about ten hours; downloading its parts,
concatenating, gzipping and re-splitting takes minutes, and produces exactly
the same graph. The uncompressed SHA-256 is verified against the source
descriptor before anything is compressed, so a corrupted download cannot be
silently republished.

Both sizes are recorded. The device needs the compressed size to show transfer
progress and verify the download, and the uncompressed size to decide up front
whether the phone has room -- at 37%, using the wrong one understates the real
footprint by a factor of nearly three.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys

PART_BYTES = 1992294400  # 1900 MiB, matching run_continent_routing.sh
CHUNK = 1024 * 1024


def run(cmd, **kwargs):
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise SystemExit(f'command failed: {" ".join(cmd)}\n{result.stderr[-2000:]}')
    return result.stdout


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b''):
            digest.update(chunk)
    return digest.hexdigest()


def split_and_compress(path, parts_dir, archive_name):
    """Splits first, then gzips each part as its own gzip member.

    Order matters. Compressing the whole archive and slicing the result gives
    parts that are meaningless alone, so the device must fetch every one before
    it can inflate anything: peak disk becomes the compressed archive plus the
    expanded one, 42.6 GB for Europe against a 31 GB result.

    Gzip is a multi-member format, so concatenating independently compressed
    parts is still one valid stream, while each part also stands alone. That
    lets the device inflate each part as it arrives, append, and delete it --
    peak disk falls to the expanded archive plus one part in flight, and an
    interrupted download resumes at a part boundary instead of restarting.

    Measured on 600 MB of a real graph: byte-identical after a round trip, each
    part inflatable alone, and the independent members were 4,555 bytes
    *smaller* than the single stream. There is no compression penalty.

    Parts are cut on the uncompressed side at 1900 MiB. Cutting to a target
    compressed size would need the ratio in advance, and a poorly compressing
    stretch could then overshoot the release asset limit.
    """
    os.makedirs(parts_dir, exist_ok=True)
    for stale in os.listdir(parts_dir):
        os.remove(os.path.join(parts_dir, stale))
    written = []
    with open(path, 'rb') as source:
        index = 1
        while True:
            raw = os.path.join(parts_dir, f'.raw{index:03d}')
            remaining = PART_BYTES
            with open(raw, 'wb') as chunk:
                while remaining:
                    block = source.read(min(CHUNK, remaining))
                    if not block:
                        break
                    chunk.write(block)
                    remaining -= len(block)
            if os.path.getsize(raw) == 0:
                os.remove(raw)
                break
            part_path = os.path.join(
                parts_dir, f'{archive_name}.gz.part{index:03d}')
            with open(part_path, 'wb') as out:
                subprocess.run(['gzip', '-6', '-n', '-c', raw],
                               stdout=out, check=True)
            written.append({
                'path': part_path,
                'uncompressedBytes': os.path.getsize(raw),
                'uncompressedSha256': sha256_of(raw),
            })
            os.remove(raw)
            index += 1
    return written


def verify_reassembly(parts, expected_sha):
    """The parts must concatenate back to exactly what was compressed."""
    digest = hashlib.sha256()
    for part in parts:
        with open(part, 'rb') as handle:
            for chunk in iter(lambda: handle.read(CHUNK), b''):
                digest.update(chunk)
    actual = digest.hexdigest()
    if actual != expected_sha:
        raise SystemExit(
            f'reassembled parts hash {actual}, expected {expected_sha}')


def fetch_descriptor(repository, tag, graph_id, work):
    name = f'{graph_id}-routing-{tag.split("-")[-1]}.vtiles.descriptor.json'
    run(['gh', 'release', 'download', tag, '-R', repository,
         '--pattern', name, '--dir', work, '--clobber'])
    with open(os.path.join(work, name), encoding='utf-8') as handle:
        return json.load(handle)


def download_parts(repository, tag, descriptor, work):
    """Fetches every part and reassembles the original archive."""
    routing = descriptor['routing']
    target = os.path.join(work, routing['file'])
    parts = routing.get('parts') or []
    if parts:
        with open(target, 'wb') as out:
            for part in parts:
                name = part['file']
                run(['gh', 'release', 'download', tag, '-R', repository,
                     '--pattern', name, '--dir', work, '--clobber'])
                downloaded = os.path.join(work, name)
                if os.path.getsize(downloaded) != part['exactBytes']:
                    raise SystemExit(f'{name}: unexpected size')
                with open(downloaded, 'rb') as handle:
                    shutil.copyfileobj(handle, out, CHUNK)
                os.remove(downloaded)
    else:
        run(['gh', 'release', 'download', tag, '-R', repository,
             '--pattern', routing['file'], '--dir', work, '--clobber'])
    # The whole point of recompressing rather than rebuilding is that the graph
    # is unchanged; prove it before spending anything on compression.
    actual = sha256_of(target)
    if actual != routing['sha256']:
        raise SystemExit(
            f'{routing["file"]}: reassembled {actual}, expected {routing["sha256"]}')
    return target


def descriptor_from_plan(plan_path, plan_sha_path, sources_path, archive):
    """Builds a descriptor for a graph that was never published.

    Europe crashed before the runner reached its split-and-describe step, so
    unlike the other six it has no published descriptor to start from. The
    plan the runner wrote up front already carries the region list, bounds and
    provenance, which is everything the descriptor needs besides the archive's
    own measurements.
    """
    with open(plan_path, encoding='utf-8') as handle:
        plan = json.load(handle)
    with open(sources_path, encoding='utf-8') as handle:
        sources = json.load(handle)
    with open(plan_sha_path, encoding='utf-8') as handle:
        plan_sha = handle.read().strip().split()[0]
    source_set = hashlib.sha256(
        json.dumps(sources, sort_keys=True, separators=(',', ':')).encode()
    ).hexdigest()
    return {
        'schemaVersion': 3,
        'routingPlanSha256': plan_sha,
        'graphId': plan['graphId'],
        'continentCode': plan['continentCode'],
        'continentName': plan['continentName'],
        'regionIds': plan['regionIds'],
        'bundleType': plan.get('bundleType', 'continent-routing'),
        'selectionMode': plan.get('selectionMode', 'optional'),
        'default': plan.get('default', False),
        'supersedesExistingRouting': plan.get('supersedesExistingRouting', False),
        'catalogIntegrated': plan.get('catalogIntegrated', False),
        'routing': {
            'format': 'valhalla-tar', 'engine': 'valhalla',
            'engineVersion': '3.6.3', 'graphId': plan['graphId'],
            'bounds': plan['bounds'],
            'file': os.path.basename(archive),
            'exactBytes': os.path.getsize(archive),
            'sha256': sha256_of(archive),
            'sourceSetSha256': source_set,
            'sourceInputs': sources,
            'parts': [],
            'updatedAt': plan['updatedAt'],
            'version': plan['version'],
            'modes': ['driving', 'walking', 'bicycling'],
            'attribution': '© OpenStreetMap contributors',
            'attributionUrl': 'https://www.openstreetmap.org/copyright',
            'license': 'ODbL-1.0',
            'licenseUrl': 'https://opendatacommons.org/licenses/odbl/1-0/',
            'sourceProvider': 'Geofabrik',
            'sourceUrl': 'https://download.geofabrik.de/',
        },
    }


def recompress(repository, source_tag, target_tag, graph_id, work, dry_run,
               local_archive=None, plan_dir=None):
    print(f'\n=== {graph_id} ===', flush=True)
    if local_archive:
        # Never published, so there is nothing to download or verify against;
        # the archive on disk is the authority.
        descriptor = descriptor_from_plan(
            os.path.join(plan_dir, f'{graph_id}-plan.json'),
            os.path.join(plan_dir, f'{graph_id}-plan.json.sha256'),
            os.path.join(plan_dir, f'{graph_id}-sources.json'),
            local_archive)
        archive = local_archive
        routing = descriptor['routing']
        plain_bytes = routing['exactBytes']
        print(f'  local {routing["file"]}  {plain_bytes/1e9:.1f} GB', flush=True)
        print(f'  {len(descriptor["regionIds"])} regions, sha '
              f'{routing["sha256"][:16]}', flush=True)
    else:
        descriptor = fetch_descriptor(repository, source_tag, graph_id, work)
        routing = descriptor['routing']
        plain_bytes = routing['exactBytes']
        print(f'  source {routing["file"]}  {plain_bytes/1e9:.1f} GB', flush=True)
        archive = download_parts(repository, source_tag, descriptor, work)
        print('  reassembled and verified against the published SHA-256',
              flush=True)

    parts_dir = os.path.join(work, f'{graph_id}-parts')
    parts = split_and_compress(archive, parts_dir, routing['file'])
    # A locally built archive is the only copy; keep it until it is uploaded.
    if not local_archive:
        os.remove(archive)
    exact_bytes = sum(os.path.getsize(p['path']) for p in parts)
    ratio = exact_bytes / plain_bytes * 100
    print(f'  {len(parts)} independently gzipped part(s), '
          f'{exact_bytes/1e9:.1f} GB ({ratio:.0f}% of raw)', flush=True)

    # The concatenated members must still be one valid gzip stream, because
    # that is what the device ends up with if it assembles before inflating.
    checksum = hashlib.sha256()
    for part in parts:
        with open(part['path'], 'rb') as handle:
            for block in iter(lambda: handle.read(CHUNK), b''):
                checksum.update(block)
    checksum = checksum.hexdigest()

    # The graph data is unchanged, so the data version stays as published.
    # Only the packaging moved, which the new tag records. Renaming the assets
    # would imply a rebuild that did not happen.
    version = routing['version']
    base = f'https://github.com/{repository}/releases/download/{target_tag}'
    # The logical assembled artifact: concatenating the gzip members yields
    # this file, and inflating it yields the original .tar.
    assembled = f'{routing["file"]}.gz'
    routing.update({
        'file': assembled,
        'exactBytes': exact_bytes,
        'sha256': checksum,
        'compression': 'gzip',
        'uncompressedBytes': plain_bytes,
        'uncompressedSha256': descriptor['routing']['sha256'],
        'version': version,
        # Each part carries both sizes so the device can show real progress
        # while inflating, verify each part the moment it lands, and resume
        # from the next boundary if the transfer stops.
        'partCompression': 'gzip-member',
        'parts': [
            {
                'file': os.path.basename(part['path']),
                'exactBytes': os.path.getsize(part['path']),
                'sha256': sha256_of(part['path']),
                'uncompressedBytes': part['uncompressedBytes'],
                'uncompressedSha256': part['uncompressedSha256'],
                'downloadUrl': f'{base}/{os.path.basename(part["path"])}',
            }
            for part in parts
        ],
    })
    descriptor['routing'] = routing
    out_name = f'{graph_id}-routing-{version}.vtiles.descriptor.json'
    out_path = os.path.join(work, out_name)
    with open(out_path, 'w', encoding='utf-8') as handle:
        json.dump(descriptor, handle, indent=2, sort_keys=True)

    if dry_run:
        print('  dry run: nothing uploaded', flush=True)
    else:
        for asset in [p['path'] for p in parts] + [out_path]:
            for attempt in range(1, 6):
                try:
                    run(['gh', 'release', 'upload', target_tag, asset,
                         '-R', repository, '--clobber'])
                    break
                except SystemExit:
                    if attempt == 5:
                        raise
        print(f'  uploaded {len(parts)} part(s) + descriptor', flush=True)

    for part in parts:
        os.remove(part['path'])
    return plain_bytes, exact_bytes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', default='virbula/offlinemaps')
    parser.add_argument('--source-tag', default='')
    parser.add_argument('--target-tag', required=True)
    parser.add_argument('--graphs', required=True,
                        help='comma separated graph ids to recompress')
    parser.add_argument('--work-dir', required=True)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--local-archive',
                        help='compress this local .tar instead of downloading; '
                             'for a graph that was never published')
    parser.add_argument('--plan-dir',
                        help='control directory holding <graph>-plan.json, '
                             'its .sha256 and <graph>-sources.json')
    args = parser.parse_args()

    os.makedirs(args.work_dir, exist_ok=True)
    graphs = [g.strip() for g in args.graphs.split(',') if g.strip()]
    total_plain = total_gz = 0
    for graph_id in graphs:
        plain, compressed = recompress(
            args.repository, args.source_tag, args.target_tag,
            graph_id, args.work_dir, args.dry_run,
            args.local_archive, args.plan_dir)
        total_plain += plain
        total_gz += compressed
    print(f'\n  {len(graphs)} graph(s): {total_plain/1e9:.1f} GB -> '
          f'{total_gz/1e9:.1f} GB ({total_gz/total_plain*100:.0f}%), '
          f'{(total_plain-total_gz)/1e9:.1f} GB saved')
    return 0


if __name__ == '__main__':
    sys.exit(main())
