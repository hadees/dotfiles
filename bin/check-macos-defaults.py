#!/usr/bin/env python3
import argparse, re, requests, sys

TESTED_HEADER = '- **Tested on macOS**:'


def parse_defaults(file_path):
    cmds = []
    regex = re.compile(r'^\s*(?:sudo\s+)?defaults\s+write\s+(\S+)\s+"?([\w.-]+)"?')
    with open(file_path) as f:
        for line in f:
            m = regex.match(line)
            if m:
                domain, key = m.groups()
                cmds.append((domain, key))
    return cmds


def domain_to_folder(domain):
    if domain.lower() == 'nsglobaldomain':
        return 'nsglobaldomain'
    m = re.match(r'com\.apple\.(.+)', domain)
    if m:
        return m.group(1).lower()
    return domain.lower()


def fetch_doc(domain, key):
    folder = domain_to_folder(domain)
    file = key.lower() + '.md'
    url = f'https://raw.githubusercontent.com/yannbertrand/macos-defaults/main/docs/{folder}/{file}'
    resp = requests.get(url)
    if resp.status_code == 200:
        return resp.text
    return None


def parse_versions(doc_text):
    versions = []
    lines = doc_text.splitlines()
    for i, line in enumerate(lines):
        if line.strip().startswith(TESTED_HEADER):
            for j in range(i+1, len(lines)):
                ln = lines[j].strip()
                if ln.startswith('- '):
                    versions.append(ln[2:].strip())
                else:
                    break
            break
    return versions


def main():
    parser = argparse.ArgumentParser(description='Check macOS defaults compatibility.')
    parser.add_argument('macos_file', help='Path to .macos file')
    parser.add_argument('version', help='macOS version name, e.g., Ventura')
    args = parser.parse_args()

    cmds = parse_defaults(args.macos_file)
    if not cmds:
        print('No defaults commands found')
        return

    unsupported = []
    for domain, key in cmds:
        doc = fetch_doc(domain, key)
        if not doc:
            unsupported.append((domain, key, 'No doc found'))
            continue
        versions = parse_versions(doc)
        if args.version not in versions:
            unsupported.append((domain, key, 'Version not listed'))

    if unsupported:
        print('Commands potentially unsupported on', args.version)
        for domain, key, reason in unsupported:
            print(f'  {domain} {key} - {reason}')
    else:
        print('All commands supported for', args.version)

if __name__ == '__main__':
    main()
