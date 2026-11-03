"""Read SHA-scoped intended-change rows for publish preflight."""
import os
import re
import sys


def version_engine_sha(version):
    info = os.path.join(version, 'BUILD-INFO')
    try:
        with open(info, encoding='utf-8') as handle:
            for line in handle:
                if line.startswith('zenoforge_sha='):
                    value = line.partition('=')[2].strip().lower()
                    if re.fullmatch(r'[0-9a-f]{40}', value):
                        return value
                    return 'unknown'
    except OSError:
        pass
    return 'unknown'


def load(path, version):
    """Return {engine-relative path: reason} rows matching this version's engine SHA."""
    engine_sha = version_engine_sha(version)
    intended = {}
    handle = open(path, encoding='utf-8')
    with handle:
        for line in handle:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            fields = line.split('\t')
            rel = fields[0]
            reason = fields[1].strip() if len(fields) > 1 else ''
            if not reason:
                raise ValueError(f'intended-changes: row without a reason: {rel}')
            sha = fields[2].strip().lower() if len(fields) > 2 else None
            if len(fields) > 3:
                raise ValueError(f'intended-changes: too many columns: {rel}')
            matches = bool(sha and re.fullmatch(r'[0-9a-f]{7,40}', sha)
                           and engine_sha != 'unknown' and engine_sha.startswith(sha))
            if matches:
                intended[rel] = reason
                continue
            shown_sha = sha or 'missing'
            if os.environ.get('ZF_INTENDED_WARNINGS_SUPPRESSED') != '1':
                print(f'intended-changes: ignoring stale row {rel} (sha {shown_sha}, new engine {engine_sha})',
                      file=sys.stderr)
    return intended
