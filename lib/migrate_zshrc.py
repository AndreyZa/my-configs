#!/usr/bin/env python3
"""Extract personal zsh blocks without executing the previous configuration.

This is deliberately conservative around framework loaders. An ambiguous block
stops activation rather than silently dropping personal code or loading a shell
framework twice. Zsh itself validates syntax; source text never appears in errors.
"""
from difflib import SequenceMatcher
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


HEADER = '# my-configs: phased local configuration v1\n'
EARLY_BEGIN = '# my-configs: early begin\n'
EARLY_END = '# my-configs: early end\n'
LATE_BEGIN = '# my-configs: late begin\n'
LATE_END = '# my-configs: late end\n'
EXISTING_BEGIN = '# my-configs: existing local begin\n'
GUARD = 'if [[ ${_MY_CONFIGS_LOCAL_PHASE:-late} == early ]]; then\n'
GUARD_END = '  return\nfi\n'


class MigrationError(Exception):
    pass


def syntax(text):
    # Disable user and optional global rc files; -n never executes input code.
    result = subprocess.run(['zsh', '-dfn'], input=text.encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=dict(os.environ, LC_ALL='C'))
    return result.returncode, result.stderr


def meaningful(text):
    lines = text.splitlines(keepends=True)
    while lines and (not lines[0].strip() or lines[0].lstrip().startswith('#')):
        lines.pop(0)
    return ''.join(lines).strip()


def normalized(text):
    return meaningful(text)


def blocks(text, label):
    """Retain complete top-level commands including comments and heredoc bytes."""
    if not text:
        return []
    if '\0' in text:
        raise MigrationError(f'{label}: NUL bytes are not supported')
    if syntax(text)[0]:
        raise MigrationError(f'{label}: invalid zsh syntax; configuration preserved')
    result = []
    pending = ''
    first = 1
    for number, line in enumerate(text.splitlines(keepends=True), 1):
        pending += line
        code = meaningful(pending)
        if not code:
            continue
        # Zsh accepts a pending escaped newline or "function name" at EOF.
        tail = line.rstrip('\r\n')
        if (len(tail) - len(tail.rstrip('\\'))) % 2:
            continue
        if re.fullmatch(r'function\s+[\w:.-]+(?:\s+[\w:.-]+)*(?:\s*\(\s*\))?\s*(?:#.*)?', code):
            continue
        if syntax(pending)[0]:
            continue
        # An unfinished heredoc also passes -n. An unmatched closing parenthesis
        # must be a syntax error rather than being swallowed as heredoc content.
        sentinel_status, sentinel_error = syntax(pending + '\n)\n')
        if not sentinel_status or b'parse error near' not in sentinel_error:
            continue
        result.append((first, pending))
        pending = ''
        first = number + 1
    if meaningful(pending):
        raise MigrationError(f'{label}: cannot safely split block at line {first}')
    if pending and result:
        line, last = result[-1]
        result[-1] = (line, last + pending)
    return result


LOADER_WORDS = re.compile(
    r'oh-my-zsh\.sh|p10k-instant-prompt|\.p10k\.zsh|'
    r'powerlevel10k\.zsh-theme|zsh-autosuggestions\.zsh|'
    r'zsh-syntax-highlighting\.zsh|(?:fzf[^\n;]*key-bindings\.zsh)|'
    r'\.zshrc(?:\.local)?(?:[\s"\';)]|$)|fzf\s+--zsh')


ARGUMENT = r'(?:"[^"\n]+"|\x27[^\x27\n]+\x27|[^\s;&|]+)'
FILE_TEST = (r'(?:\[\[\s+(?:!\s+)?-[fres]\s+' + ARGUMENT + r'\s+\]\]|'
             r'\[\s+(?:!\s+)?-[fres]\s+' + ARGUMENT + r'\s+\])')
SOURCE = re.compile(r'^(?:source|\.)\s+(' + ARGUMENT + r')$')


def known_source(code):
    match = SOURCE.fullmatch(code)
    if not match:
        return False
    argument = match.group(1)
    if argument[0] in ('"', "'"):
        argument = argument[1:-1]
    # Substitutions in loader targets may have arbitrary side effects.
    if '$(' in argument or '`' in argument:
        return False
    if argument in ('$ZSH/oh-my-zsh.sh', '${ZSH}/oh-my-zsh.sh',
                    '$HOME/.oh-my-zsh/oh-my-zsh.sh', '${HOME}/.oh-my-zsh/oh-my-zsh.sh',
                    '~/.oh-my-zsh/oh-my-zsh.sh'):
        return True
    if re.fullmatch(r'(?:~|\$HOME|\$\{HOME\}|\$\{ZDOTDIR:-\$HOME\})/\.(?:p10k\.zsh|zshrc\.local)', argument):
        return True
    if argument.startswith('${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-') and argument.endswith('.zsh'):
        return True
    if re.fullmatch(r'\$(?:ZSH_CUSTOM|\{ZSH_CUSTOM\})/plugins/(zsh-autosuggestions|zsh-syntax-highlighting)/\1\.zsh', argument):
        return True
    return argument in (
        '/usr/share/doc/fzf/examples/key-bindings.zsh', '/usr/share/fzf/key-bindings.zsh',
        '/opt/homebrew/opt/fzf/shell/key-bindings.zsh', '/usr/local/opt/fzf/shell/key-bindings.zsh',
        '$FZF_BASE/shell/key-bindings.zsh', '${FZF_BASE}/shell/key-bindings.zsh',
        '$HOME/.fzf/shell/key-bindings.zsh', '~/.fzf/shell/key-bindings.zsh')


def known_loader_line(code):
    if known_source(code):
        return True
    guarded = re.fullmatch(FILE_TEST + r'\s*(?:&&|\|\|)\s*(.+)', code)
    return bool(guarded and '$(' not in code and '`' not in code
                and known_source(guarded.group(1)))


def loader_block(text):
    """Return True only for narrowly recognized loader-only legacy blocks."""
    code = meaningful(text)
    # A function merely defining a command is personal code, not startup loading.
    if re.match(r'(?:function\s+[\w:.-]+|[\w:.-]+\s*\(\s*\))\s*\{', code):
        return False
    # Mentioning a configuration pathname in an alias or exported value does not
    # source it. Tokenize only these simple declarations, never evaluate them.
    try:
        lexer = shlex.shlex(code, posix=True, punctuation_chars=';&|')
        lexer.whitespace_split = True
        words = list(lexer)
        if words and words[0] in ('alias', 'export', 'typeset'):
            assignments = [w for w in words[1:] if not re.fullmatch(r'-[A-Za-z]+', w)]
            if assignments and all(re.match(r'^[A-Za-z_][A-Za-z_0-9-]*=', w) for w in assignments):
                return False
    except ValueError:
        pass
    if not LOADER_WORDS.search(code):
        return False
    lines = [x.strip() for x in code.splitlines()
             if x.strip() and not x.lstrip().startswith('#')]
    # Common guarded one-line loaders. The target must name a known integration;
    # a second command separated by ;, && or || is never silently discarded.
    if len(lines) == 1 and known_loader_line(lines[0]):
        return True
    if (lines and '$(' not in lines[0] and '`' not in lines[0]
            and re.fullmatch(r'if\s+' + FILE_TEST + r';\s*then', lines[0]) and lines[-1] == 'fi'):
        body = lines[1:-1]
        for item in body:
            if known_loader_line(item):
                continue
            # These bindings are supplied by the new template as well.
            if re.fullmatch(r"bindkey -M (?:emacs|viins) ['\"]\^\[\^F['\"] fzf-file-widget", item):
                continue
            return None
        return bool(body)
    # eval "$(fzf --zsh)" is a dedicated loader; other evals remain personal code.
    if re.fullmatch(r'eval\s+"\$\(fzf --zsh(?: 2>/dev/null)?\)"', code):
        return True
    return None


def early_setting(text):
    # Settings consumed before loading Oh My Zsh must precede its initialization.
    # Other personal statements stay together in their original order, late.
    code = meaningful(text)
    return bool(re.match(r'(?:(?:export|typeset(?: -[A-Za-z]+)?)\s+)?'
                         r'(?:ZSH|ZSH_[A-Za-z_]+|DISABLE_[A-Za-z_]+|plugins)=', code))


def read_optional(path):
    p = Path(path)
    if not p.exists():
        return ''
    if not p.is_file():
        raise MigrationError('Expected a regular configuration file')
    return p.read_bytes().decode('utf-8')


def unpack_local(text):
    if not text.startswith(HEADER):
        return [], [], text
    markers = [EARLY_BEGIN, EARLY_END, LATE_BEGIN, LATE_END, EXISTING_BEGIN]
    if any(text.count(marker) != 1 for marker in markers):
        raise MigrationError('Existing phased local configuration has ambiguous markers')
    try:
        early = text.split(EARLY_BEGIN, 1)[1].split(EARLY_END, 1)[0]
        late = text.split(LATE_BEGIN, 1)[1].split(LATE_END, 1)[0]
        existing = text.split(EXISTING_BEGIN, 1)[1]
        if not early.startswith(GUARD) or not early.endswith(GUARD_END):
            raise ValueError()
        early = early[len(GUARD):-len(GUARD_END)]
        # Marker edits and personal statements between generated sections must
        # never disappear when another migration causes this file to be rendered.
        if render([early] if early else [], [late] if late else [], existing) != text:
            raise ValueError()
    except (IndexError, ValueError):
        raise MigrationError('Existing phased local configuration was edited; review before migration')
    return [t for _, t in blocks(early, 'existing early settings')], \
        [t for _, t in blocks(late, 'existing migrated settings')], existing


def render(early, late, existing):
    def joined(items):
        return ''.join(item if item.endswith('\n') else item + '\n' for item in items)
    return (HEADER + EARLY_BEGIN + GUARD + joined(early) + GUARD_END + EARLY_END +
            LATE_BEGIN + joined(late) + LATE_END + EXISTING_BEGIN + existing)


def declaration_keys(text):
    """Over-approximate names changed by a block, without interpreting its values.

    Keeping an extra original declaration is safe; deleting a later reset after
    a personal override is not. This includes declarations inside compound code.
    """
    code = meaningful(text)
    keys = set()
    try:
        lexer = shlex.shlex(code, posix=True, punctuation_chars=';&|(){}')
        lexer.whitespace_split = True
        words = list(lexer)
    except ValueError:
        words = []
    for index, word in enumerate(words):
        match = re.match(r'^([A-Za-z_][A-Za-z_0-9]*)(?:\+)?=', word)
        if match:
            keys.add(('variable', match.group(1)))
        if word in ('alias', 'unalias', 'unset'):
            for following in words[index + 1:]:
                if following in (';', '&&', '||', '|', 'then', 'fi', '}', ')'):
                    break
                match = re.match(r'^([A-Za-z_][A-Za-z_0-9-]*)(?:=|$)', following)
                if match:
                    keys.add(('variable' if word == 'unset' else 'alias', match.group(1)))
    for match in re.finditer(r'(?:^|[;\n])\s*(?:function\s+([\w:.-]+)|([\w:.-]+)\s*\(\s*\))', code):
        keys.add(('function', match.group(1) or match.group(2)))
    return keys


def migrate(old, template, baseline, local):
    reference = blocks(baseline if baseline else template, 'template')
    early, late, existing = unpack_local(local)
    existing_blocks = blocks(existing, 'existing local configuration')
    # Equal text in another phase cannot replace execution before/after OMZ.
    seen_early = {normalized(t) for t in early}
    seen_late = {normalized(t) for t in late + [t for _, t in existing_blocks]}
    changed = False
    new_early, new_late = [], []
    old_blocks = blocks(old, 'previous configuration')
    reference_keys = [normalized(text) for _, text in reference]
    old_keys = [normalized(text) for _, text in old_blocks]
    known = set()
    for match in SequenceMatcher(None, reference_keys, old_keys, autojunk=False).get_matching_blocks():
        known.update(range(match.b, match.b + match.size))
    # A user may deliberately restore a shared default after a personal override.
    # Carry every declaration of the affected names, preserving that last write.
    modified_names = set()
    for index, (_, text) in enumerate(old_blocks):
        if index not in known:
            modified_names.update(declaration_keys(text))
    primary = next((number for number, text in old_blocks
                    if 'oh-my-zsh.sh' in meaningful(text) and loader_block(text) is True), None)
    existing_early_names = {name for text in early for name in declaration_keys(text)}
    # Without an explicit framework boundary, only independent declarations can
    # move early. A theme selected from another late variable must not silently
    # become empty merely because its assignment was moved ahead of that value.
    stable_names = {'HOME', 'ZDOTDIR', 'USER', 'LOGNAME', 'SHELL', 'TERM',
                    'OSTYPE', 'MACHTYPE', 'HOST', 'HOSTNAME', 'PWD',
                    'XDG_CONFIG_HOME', 'XDG_CACHE_HOME'}
    late_variable_names = {name for _, text in old_blocks if not early_setting(text)
                           for kind, name in declaration_keys(text) if kind == 'variable'}
    available_early_names = stable_names - late_variable_names
    for index, (number, text) in enumerate(old_blocks):
        key = normalized(text)
        is_early = number < primary if primary is not None else early_setting(text)
        seen = seen_early if is_early else seen_late
        if not key or key in seen:
            continue
        if index in known and not declaration_keys(text).intersection(modified_names):
            continue
        loader = loader_block(text)
        if loader is None:
            raise MigrationError(f'Previous configuration: mixed or unrecognized loader at line {number}; review required')
        if loader:
            continue
        declarations = declaration_keys(text)
        if not is_early and declarations.intersection(existing_early_names):
            raise MigrationError(f'Previous configuration: initialization conflict at line {number}; review required')
        if is_early and primary is None:
            code = meaningful(text)
            referenced = set(re.findall(r'\$(?:\{)?([A-Za-z_][A-Za-z_0-9]*)', code))
            if '$(' in code or '`' in code or referenced - available_early_names:
                raise MigrationError(f'Previous configuration: ambiguous initialization dependency at line {number}; review required')
            available_early_names.update(name for kind, name in declarations if kind == 'variable')
        # Preserve the original order and dependencies of the user's pre-OMZ
        # preamble (including compound PATH filters), without evaluating it here.
        (new_early if is_early else new_late).append(text)
        changed = True
    if not changed:
        return local
    # Already-active local preferences win over settings recovered from an older
    # backup. Within each source, order and dependencies remain unchanged.
    merged = render(new_early + early, new_late + late, existing)
    if syntax(merged)[0]:
        raise MigrationError('Merged local configuration failed syntax validation')
    return merged


def main():
    if len(sys.argv) != 6:
        raise MigrationError('Usage: migrate_zshrc.py OLD TEMPLATE BASELINE LOCAL OUTPUT')
    old, template, baseline, local, output = sys.argv[1:]
    merged = migrate(read_optional(old), read_optional(template),
                     read_optional(baseline), read_optional(local))
    Path(output).write_text(merged, encoding='utf-8')
    os.chmod(output, 0o600)


if __name__ == '__main__':
    try:
        main()
    except (MigrationError, OSError, UnicodeError) as error:
        # Never echo source text: aliases and exports can contain credentials.
        message = str(error) if isinstance(error, MigrationError) else 'Could not read or write migration files'
        print('Migration error: ' + message, file=sys.stderr)
        sys.exit(1)
