#!/usr/bin/env python3
# Запуск команды с переменными .env проекта; вызов от node из скрипта запуска: claude-box-env <файл .env> <команда> [аргументы…]
# Разбор — по правилам env_file Docker Compose (compose-go: dotenv и template): кавычки, экранирование, подстановки ${…}.
# Подстановки и строки из одного имени берут значения из окружения контейнера — у Compose это окружение хоста.
import os
import re
import sys

SPACE = '\t\v\f\r \x85\xa0'
ESCAPE = re.compile(r'\\(?:[abcfnrtv$"\\]|0[0-9]{0,3})')
ESCAPES = {'a': '\a', 'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t', 'v': '\v', '"': '"', '\\': '\\', '$': '$$'}
VAR = re.compile(r'\$(?:(?P<escaped>\$)|(?P<named>[_a-z][_a-z0-9]*)|\{(?:(?P<braced>[_a-z][_a-z0-9]*(?::?[-+?](.*))?)\}|(?P<invalid>)))', re.I)
NAME = re.compile(r'[_a-z][_a-z0-9]*', re.I)
# ключи входа и переключатели провайдера: Claude Code в контейнере работает по подписке, программы агента их тоже не видят
LOGIN = ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN',
         'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY')


class EnvError(Exception):
    pass


def unescape(m):
    s = m.group()
    if s[1] != '0':
        return ESCAPES.get(s[1], s)
    # \0 и три восьмеричные цифры — символ; прочее теряет только ноль, как у Compose
    d = s[2:]
    if len(d) == 3 and set(d) <= set('01234567') and int(d, 8) < 256:
        return chr(int(d, 8))
    return '\\' + d


def closing(s):
    # первая закрывающая скобка на нулевой глубине; символ после открывающей пропускается
    depth, i = 0, 0
    while i < len(s):
        if s[i] == '}':
            depth -= 1
            if depth == 0:
                return i
        if s[i] == '{':
            depth += 1
            i += 1
        i += 1
    return -1


def substitute(text, look):
    def repl(m):
        if m.group('escaped') is not None:
            return '$'
        if m.group('named') is not None:
            return look(m.group('named')) or ''
        if m.group('braced') is None:
            raise EnvError(f'неверная подстановка: {text}')
        s = m.group()
        end = closing(s)
        if end >= 0:
            s, rest = s[:end + 1], s[end + 1:]
        else:
            rest = ''
        body = s[2:-1]
        name = NAME.match(body).group()
        mod = body[len(name):]
        value = look(name)
        if not mod:
            return value or ''
        op = mod[:2] if mod[:2] in (':-', ':+', ':?') else mod[:1]
        word = mod[len(op):]
        empty = value is None or (op[0] == ':' and value == '')
        if op[-1] == '-':
            value = substitute(word, look) if empty else value
        elif op[-1] == '+':
            value = '' if empty else substitute(word, look)
        elif empty:
            raise EnvError(f'нет значения {name}: {substitute(word, look)}')
        return value + substitute(rest, look)
    return VAR.sub(repl, text)


def parse(src, env):
    out = {}
    line = 1

    def look(k):
        return env[k] if k in env else out.get(k)

    while True:
        # начало записи: пробелы и строки-комментарии пропускаются
        stripped = src.lstrip()
        line += src[:len(src) - len(stripped)].count('\n')
        src = stripped
        if not src:
            return out
        if src[0] == '#':
            nl = src.find('\n')
            if nl < 0:
                return out
            src = src[nl:]
            continue
        if re.match(r'export\s', src):
            src = src[6:].lstrip(SPACE)
        # имя — до «=», «:» или конца строки; строка из одного имени берёт значение из окружения
        end, sep = len(src), ''
        for i, c in enumerate(src):
            if c in '=:\n':
                end, sep = i, c
                break
            if not (c in SPACE or c in '_.-[]' or c.isalnum()):
                raise EnvError(f'строка {line}: символ {c!r} в имени {src.split(chr(10))[0]!r}')
        key = src[:end].rstrip()
        src = src[end + 1:].lstrip(SPACE)
        if ' ' in key:
            raise EnvError(f'строка {line}: пробел в имени {key!r}')
        if sep in ('\n', ''):
            line += 1
            if key in env:
                out[key] = env[key]
            continue
        if not key:
            raise EnvError(f'строка {line}: пустое имя')
        if src[:1] not in ('"', "'"):
            # без кавычек: до конца строки, комментарий после « #» и хвостовые пробелы отбрасываются
            value, _, src = src.partition('\n')
            line += 1
            out[key] = substitute(value.split(' #')[0].rstrip(), look)
            continue
        # в кавычках: до непарной закрывающей, переносы строк — часть значения
        quote, chars, esc = src[0], [], False
        for i in range(1, len(src)):
            c = src[i]
            if c == '\n':
                line += 1
            if c != quote:
                if not esc and c == '\\':
                    esc = True
                    continue
                if esc:
                    esc = False
                    chars.append('\\')
                chars.append(c)
                continue
            if esc:
                esc = False
                chars.append(c)
                continue
            value = ''.join(chars)
            if quote == '"':
                value = substitute(ESCAPE.sub(unescape, value), look)
            out[key] = value
            src = src[i + 1:]
            break
        else:
            raise EnvError(f'строка {line}: нет закрывающей кавычки {src.split(chr(10))[0]}')


def main():
    path, cmd = sys.argv[1], sys.argv[2:]
    env = dict(os.environ)
    try:
        with open(path, encoding='utf-8') as f:
            src = f.read()
    except FileNotFoundError:
        src = ''
    try:
        # два прохода, как у Compose: ссылка на имя ниже по файлу берёт его значение из первого прохода
        project = {**parse(src, env), **env}
        values = parse(src, project)
    except EnvError as e:
        sys.exit(f'claude-box: {path}: {e}')
    # имена, уже заданные образом, compose-файлом и движком, .env не перекрывает
    env = {**values, **env}
    for k in LOGIN:
        env.pop(k, None)
    os.execvpe(cmd[0], cmd, env)


main()
