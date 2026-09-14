#!/usr/bin/env python3
"""Check local links in the public READMEs and architecture decisions."""

from pathlib import Path
import re
import sys
from urllib.parse import unquote

sys.dont_write_bytecode = True


def anchors(document):
    counts = {}
    result = set()
    for heading in re.findall(r'^#{1,6}\s+(.+?)\s*#*$', document.read_text(encoding='utf-8'), re.MULTILINE):
        slug = re.sub(r'[^\w -]', '', heading.lower()).replace(' ', '-')
        occurrence = counts.get(slug, 0)
        counts[slug] = occurrence + 1
        result.add(slug if occurrence == 0 else '%s-%d' % (slug, occurrence))
    return result


def check(root):
    documents = [root / 'README.md', root / 'README.zh-CN.md']
    decisions = sorted((root / 'docs/adr').glob('*.md'))
    if not decisions:
        raise ValueError('architecture decisions are missing')
    documents.extend(decisions)
    checked = 0
    for document in documents:
        for target in re.findall(r'\]\(([^\s)]+)\)', document.read_text(encoding='utf-8')):
            if re.match(r'[a-zA-Z][a-zA-Z0-9+.-]*:', target):
                continue
            path, separator, fragment = unquote(target).partition('#')
            destination = document.parent / path if path else document
            if not destination.exists():
                raise ValueError('%s: missing local link %s' % (document.relative_to(root), target))
            if separator and fragment and fragment not in anchors(destination):
                raise ValueError('%s: missing local anchor %s' % (document.relative_to(root), target))
            checked += 1
    if checked == 0:
        raise ValueError('no local documentation links were checked')
    return checked


def main():
    try:
        count = check(Path(sys.argv[1]))
    except (OSError, ValueError) as error:
        print('documentation links: ' + str(error), file=sys.stderr)
        return 1
    print('documentation links: %d checked' % count)
    return 0


if __name__ == '__main__':
    sys.exit(main())
