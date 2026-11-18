"""Resolve a packaged artifact SHA from a sidecar or artifact/SHA256SUMS."""
import re
from pathlib import Path

HEX = re.compile(r'[a-fA-F0-9]{64}')
SAFE = re.compile(r'[A-Za-z0-9._-]+')


def _sidecar(path):
    for candidate in (path.with_name(path.name + '.sha256'), path.with_suffix('.sha256')):
        if not candidate.is_file():
            continue
        try:
            text = candidate.read_text(encoding='utf-8', errors='replace')[:4096]
        except OSError:
            continue
        match = HEX.search(text)
        if match:
            return match.group(0).lower()
    return None


def _manifest(project, path):
    manifest = Path(project) / 'artifact' / 'SHA256SUMS'
    if not manifest.is_file():
        return None
    wanted = {path.name, './' + path.name}
    for line in manifest.read_text(encoding='utf-8', errors='replace').splitlines():
        text = line.strip()
        if not text or text.startswith('#'):
            continue
        match = HEX.match(text)
        if not match:
            continue
        rest = text[64:].strip().lstrip('*').strip()
        if rest in wanted or Path(rest).name == path.name:
            return match.group(0).lower()
    return None


def resolve(project, artifact, explicit=''):
    """Return a supplied/sidecar/manifest SHA without hashing the archive.

    The caller must still verify the archive bytes before installation. The
    artifact path is restricted to the trusted Web project tree.
    """
    if explicit:
        match = HEX.fullmatch(str(explicit))
        return match.group(0).lower() if match else ''
    if not artifact:
        return ''
    candidate = Path(str(artifact))
    if not candidate.is_absolute() or '..' in candidate.parts or '\x00' in str(candidate):
        return ''
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(Path(project).resolve())
    except (OSError, ValueError):
        return ''
    if not resolved.is_file() or resolved.is_symlink():
        return ''
    return _sidecar(resolved) or _manifest(project, resolved) or ''
