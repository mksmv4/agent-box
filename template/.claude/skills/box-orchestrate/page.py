#!/usr/bin/env python3
# Скрипт страницы задачи оркестратора: правит файл my_local/pages/<задача>.html по меткам <!-- page:имя --> … <!-- /page:имя -->,
# всё вне меток — каркас примера examples/running.html. Данные — таск-файл, журнал цикла и текст оркестратора со stdin.
# Вызов из корня проекта: python3 .claude/skills/box-orchestrate/page.py <задача> <команда> [адрес] <<'EOF' … EOF
# Команды и форма текста — SKILL.md рядом, шаг «Страница задачи»; устройство страницы и метки — pages.md.
import base64
import html
import json
import mimetypes
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

SKELETON = Path(__file__).resolve().parent / 'examples' / 'running.html'
MARKS = ['title', 'name', 'meta', 'lead', 'where', 'updated', 'toc-ask', 'ask', 'goals', 'steps', 'now', 'its', 'its-note', 'qa']
NO_QA = '<p class="note">Вопросов пока не было.</p>'
# состояние страницы по команде; new берёт его из статуса задачи
STATE = {'iteration': 'идёт', 'question': 'ждёт решения', 'answer': 'стоит', 'stop': 'стоит', 'done': 'готово'}
# метки состояний: слово и класс цвета
RUN, WAIT, STAND = ('идёт', 'st-run'), ('ждёт решения', 'st-wait'), ('стоит', 'st-part')
FAIL, FAILED, PART = ('сбой', 'st-fail'), ('сбой', 'st-failed'), ('не закончен', 'st-part')
DONE, READY, PAST, TODO = ('сделано', 'st-done'), ('готово', 'st-done'), ('вопрос снят', 'st-past'), ('впереди', 'st-todo')
COUNT = {2: 'двух', 3: 'трёх', 4: 'четырёх'}
LETTERS = 'abcd'
ENGINE = 'движок — скрипт, который запускает Claude на шаги по очереди, —'
ORCH = 'оркестратор — Claude, который ведёт задачу, —'


def fail(code, msg):
    print(msg)
    sys.exit(code)


def esc(s):
    return html.escape(s, quote=False)


def paras(text):
    # абзацы текста оркестратора: пустая строка — граница абзаца
    return [f'<p>{esc(" ".join(p.split()))}</p>' for p in re.split(r'\n\s*\n', text.strip()) if p.strip()]


def plural(n, one, few, many):
    if n % 10 == 1 and n % 100 != 11:
        return one
    return few if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14 else many


def short(step):
    # короткое имя шага — текст до первого двоеточия, без разметки markdown
    step = step.replace('**', '').replace('`', '').strip()
    name = step.split(': ', 1)[0].rstrip(':')
    return name if len(name) <= 80 else name[:80] + '…'


def git(*args):
    return subprocess.run(['git', *args], capture_output=True, text=True, check=True).stdout.strip()


# строка этапа в «Постановке» — «Этап <N> — <название>.» в начале абзаца; этап идёт с первого шага после неё
STAGE_LINE = re.compile(r'^Этап (\d+) — ([^.\n]+)')


# таск-файл: статус, очередь шагов «Постановки» — (закрыт ли, короткое имя) — и этапы: номер шага → [(номер этапа, строка этапа)]
def read_task(path):
    text = path.read_text()
    status = re.match(r'статус: *(.*)', text)
    plan = re.search(r'^## Постановка$(.*?)(?=^## |\Z)', text, re.M | re.S)
    steps, stages, pending = [], {}, []
    for line in (plan[1] if plan else '').splitlines():
        if m := re.match(r'- \[([ x])\] (.*)$', line):
            steps.append((m[1] == 'x', short(m[2])))
            if pending:
                stages[len(steps)], pending = pending, []
        elif m := STAGE_LINE.match(line):
            pending.append((int(m[1]), f'Этап {m[1]} — {m[2].strip()}'))
    return (status[1].strip() if status else ''), steps, stages


# журнал цикла: итерации задачи по всем её запускам, номер — сквозной
EVENT = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d):\d\d (\S.*)$')
SAID = re.compile(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d   агент: (.*)$')
START = re.compile(r'^задача (.+) — итерация (\d+)/\d+, шаг (\d+)/\d+ «(.*)», сессия \S+$')
ALERT = re.compile(r'^задача (.+) — итерация \d+ идёт дольше (\d+) мин')
END = re.compile(r'^итерация \d+ закончена за (\d+) мин (\d+) с: код \S+, .*, статус «(.*)»$')
CRASH = re.compile(r'^остановка: итерация (\d+) упала')


def read_log(path, task):
    its, on, cur, commits, last = [], False, None, False, None
    lines = path.read_text(errors='replace').splitlines() if path.exists() else []
    for line in lines:
        if line.startswith('    '):
            if commits and line.startswith('    коммит '):
                cur['commits'].append(line.split()[1])
            continue
        commits = False
        if m := SAID.match(line):
            if on and cur:
                cur['said'] = m[1]
            continue
        if not (m := EVENT.match(line)):
            continue
        at, text = m.groups()
        if text.startswith('запуск: '):
            arg = text.split()[-1]
            on, cur = arg == task or Path(arg).name == task + '.md', None
            continue
        if not on:
            continue
        last = at
        if (s := START.match(text)) and s[1] == task:
            cur = dict(at=at, local=s[2], k=int(s[3]), step=short(s[4]), end=None, commits=[], said='', crash=False, alert=None)
            its.append(cur)
        elif cur and (a := ALERT.match(text)) and a[1] == task:
            cur['alert'] = a[2]
        elif cur and (e := END.match(text)):
            cur['end'] = dict(at=at, min=int(e[1]), sec=int(e[2]), status=e[3])
            commits = True
        elif cur and (c := CRASH.match(text)) and c[1] == cur['local']:
            cur['crash'] = True
    return its, last


# страница: куски между метками
def span(page, mark):
    start, end = f'<!-- page:{mark} -->', f'<!-- /page:{mark} -->'
    i = page.find(start)
    j = page.find(end, i)
    if i < 0 or j < 0:
        return None
    line = page[page.rfind('\n', 0, i) + 1:i]
    return i + len(start), j, line if not line.strip() else None


def put(page, mark, lines):
    # блочная метка — строки с её отступом, по строке на элемент; строчная — текст как есть
    i, j, indent = span(page, mark)
    if indent is None:
        inner = ''.join(lines)
    else:
        inner = ''.join(f'\n{indent}{s}' for line in lines for s in line.split('\n')) + f'\n{indent}'
    return page[:i] + inner + page[j:]


def get(page, mark):
    # строки блочной метки без её отступа
    i, j, indent = span(page, mark)
    return [s[len(indent):] for s in page[i:j].split('\n')[1:-1]]


def label(st):
    return f'<span class="st {st[1]}">{st[0]}</span>'


def outcome(its, n, state, closed):
    it, last = its[n], n == len(its) - 1
    if not it['end']:
        return RUN if last and state == 'идёт' else (FAIL if last else FAILED)
    if it['crash']:
        return FAIL if last and state != 'идёт' else FAILED
    status = it['end']['status']
    if status == 'блокер':
        return WAIT if last and state == 'ждёт решения' else PAST
    if status == 'готово' or (its[n + 1]['k'] if not last else closed + 1) > it['k']:
        return DONE
    return PART


def said(text):
    # последний текст сессии в журнале обрезан на 200 знаках — до последнего целого предложения
    text = text.replace('`', '')
    if text.endswith('…'):
        cut = max(text.rfind(p) for p in ('. ', '! ', '? '))
        if cut > 0:
            text = text[:cut + 1]
    return esc(text)


def iteration_rows(its, n, state, closed, now):
    it = its[n]
    if it['end']:
        took = f'{it["end"]["min"]} мин' if it['end']['min'] else f'{it["end"]["sec"]} с'
    elif n == len(its) - 1 and state == 'идёт':
        took = f'{int((now - datetime.strptime(it["at"], "%Y-%m-%d %H:%M")).total_seconds() // 60)} мин'
    else:
        took = 'оборвана'
    hashes = f'<span class="hash">{" ".join(it["commits"])}</span>' if it['commits'] else 'Коммитов нет.'
    text = f'{said(it["said"])} {hashes}' if it['said'] else hashes
    return [f'<tr class="it"><td class="nw">{n + 1} · {it["at"][11:]}<br>{took}</td><td>{it["k"]} · {esc(it["step"])}</td>'
            f'<td>{label(outcome(its, n, state, closed))}</td></tr>',
            f'<tr class="cm"><td colspan="3">{text}</td></tr>']


def wrap(head, rows):
    # таблица в контейнере прокрутки: на телефоне шире экрана — прокрутка внутри
    return ['<div class="scroll">', '  <table>', '    <thead><tr>' + ''.join(f'<th>{h}</th>' for h in head) + '</tr></thead>',
            '    <tbody>', *('      ' + r for r in rows), '    </tbody>', '  </table>', '</div>']


def table(its, ns, state, closed, now):
    rows, day = [], None
    for n in ns:
        if its[n]['at'][:10] != day:
            day = its[n]['at'][:10]
            rows.append(f'<tr class="day"><td colspan="3">{day}</td></tr>')
        rows += iteration_rows(its, n, state, closed, now)
    return wrap(['Итерация', 'Шаг', 'Исход'], rows)


# этапы очереди: строка этапа и пояснение под ней перед первым шагом этапа — data-stage, номер этапа
STAGE = re.compile(r'<tr class="stage(-note)?" data-stage="(\d+)">')


def note_row(n, note):
    return f'<tr class="stage-note" data-stage="{n}"><td colspan="3">{esc(note)}</td></tr>'


def read_stages(page):
    # этапы прошлой отрисовки очереди: номера и строки пояснений; пояснения задаёт только new, события переносят
    shown, notes = set(), {}
    for line in get(page, 'steps'):
        if m := STAGE.search(line):
            shown.add(int(m[2]))
            if m[1]:
                notes[int(m[2])] = line.strip()
    return shown, notes


def render_its(its, state, closed, now):
    if not its:
        return ['<p class="note">Итераций пока не было.</p>']
    ns = list(range(len(its) - 1, -1, -1))
    out = table(its, ns[:5], state, closed, now)
    if ns[5:]:
        out += ['<details>', f'  <summary>Итерации 1–{len(ns) - 5}: время, шаг, исход</summary>',
                *('  ' + s for s in table(its, ns[5:], state, closed, now)), '</details>']
    return out


def render_now(state, its, last, extra):
    it = its[-1] if its else None
    if state == 'идёт' and it and not it['end']:
        first = f'С {it["at"]} идёт итерация {len(its)}: {ENGINE} запустил сессию на шаг «{esc(it["step"])}». Сессия — Claude на одном шаге.'
        if it['alert']:
            first += f' Итерация идёт дольше {it["alert"]} мин; оркестратор следит за её ходом.'
    elif state == 'идёт' and it:
        first = f'Итерация {len(its)} кончилась в {it["end"]["at"]}; {ENGINE} запускает следующую.'
    elif state == 'идёт':
        first = f'{ENGINE[0].upper()}{ENGINE[1:]} запущен.'
    elif state == 'ждёт решения':
        first = f'Движок стоит{f" с {last}" if last else ""} и ждёт твоего решения: вопрос и что будет после каждого варианта — <a href="#ask">выше</a>. После ответа {ORCH} сделает по твоему выбору.'
    elif state == 'готово':
        first = f'Задача готова: все шаги сделаны{f", последняя итерация кончилась в {last}" if last else ""}.'
    else:
        first = f'Движок стоит{f" с {last}" if last else ""}.'
    out = [f'<p>{first}</p>']
    if state == 'идёт':
        out.append(f'<p>Дальше сессия закроет шаг или остановится на вопросе; до этого от тебя ничего не нужно. На вопрос {ORCH} ответит сам или спросит тебя в своём чате.</p>')
    return out + extra


def render_common(page, state, task_file, log, task, now, extra, notes=None):
    status, steps, stages = read_task(task_file)
    if notes is None:
        notes = read_stages(page)[1]
    its, last = read_log(log, task)
    closed = sum(done for done, _ in steps)
    total = len(steps)
    cur = next((name for done, name in steps if not done), '')
    on = {'идёт': RUN, 'ждёт решения': WAIT, 'стоит': STAND}.get(state, TODO)
    meta = ['<p class="meta">', f'  {label(READY if state == "готово" else on)}',
            f'  <span>шаг {min(closed + 1, total)} из {total}</span>',
            f'  <span>{len(its)} {plural(len(its), "итерация", "итерации", "итераций")}</span>']
    if its:
        meta.append(f'  <span>в работе с {its[0]["at"]}</span>')
    where = {
        'идёт': f'Шагов сделано — {closed} из {total}, идёт шаг «{esc(cur)}». Решения от тебя сейчас не ждут — <a href="#now">раздел «Сейчас»</a>.',
        'ждёт решения': f'Шагов сделано — {closed} из {total}, шаг «{esc(cur)}» ждёт твоего решения — <a href="#ask">к вопросу</a>.',
        'стоит': f'Шагов сделано — {closed} из {total}, движок стоит — <a href="#now">раздел «Сейчас»</a>.',
        'готово': 'Все шаги сделаны, задача готова — <a href="#now">раздел «Сейчас»</a>.',
    }[state]
    rows = []
    for k, (done, name) in enumerate(steps, 1):
        mark = DONE if done else (on if name == cur and state != 'готово' else TODO)
        for n, title in stages.get(k, []):
            rows += [f'<tr class="stage" data-stage="{n}"><td colspan="3">{esc(title)}</td></tr>', *([notes[n]] if n in notes else [])]
        rows.append(f'<tr><td class="n">{k}</td><td>{esc(name)}</td><td class="nw">{label(mark)}</td></tr>')
    page = put(page, 'meta', meta + ['</p>'])
    page = put(page, 'where', [where])
    page = put(page, 'updated', [f'<p class="note">Обновлено {now:%Y-%m-%d %H:%M} по задаче и журналу цикла.</p>'])
    page = put(page, 'steps', wrap(['№', 'Шаг', 'Состояние'], rows))
    page = put(page, 'now', render_now(state, its, last, extra))
    page = put(page, 'its', render_its(its, state, closed, now))
    if state != 'ждёт решения':
        page = put(page, 'toc-ask', [])
        page = put(page, 'ask', [])
    return page, cur, status


def look(q, root):
    # то, из чего выбирают, как его увидит читатель: текст на проверку и картинки внутри страницы адресом data:
    out = []
    if q.get('quote'):
        out += ['  <blockquote>', *('    ' + p for p in paras(q['quote'])), '  </blockquote>']
    for im in q.get('images', []):
        path = root / im['path']
        kind = mimetypes.guess_type(path.name)[0]
        if not path.is_file() or not (kind or '').startswith('image/'):
            fail(2, f'картинка вопроса {im["path"]}: нет такого файла картинки от корня проекта')
        src = f'data:{kind};base64,{base64.b64encode(path.read_bytes()).decode()}'
        # размер картинки — в атрибуте: страница, заведённая до стилей .look, держит старый каркас до new
        out += ['  <figure>', f'    <img src="{src}" alt="{esc(im["caption"])}" style="max-width: 100%; height: auto">',
                f'    <figcaption class="note">{esc(im["caption"])}</figcaption>', '  </figure>']
    return ['<p class="kind">Как это выглядит</p>', '<div class="look">', *out, '</div>'] if out else []


def render_ask(data, root):
    qs = data['questions']
    many = len(qs) > 1
    top = ['<div class="ask-top">', '  <h2>Ждёт решения</h2>']
    top += ['  <p class="q">' + (f'Вопрос {q["n"]}. ' if q.get('n') else '') + f'{esc(q["q"])}</p>' for q in qs]
    if many:
        top.append('  <p>Ответ — вариант на каждый вопрос в окне вопроса в чате оркестратора — Claude, который ведёт задачу. Свой вариант окно примет текстом.</p>')
    else:
        top.append(f'  <p>Ответ — один из <a href="#opts-1">{COUNT.get(len(qs[0]["options"]), "")} вариантов ниже</a> в окне вопроса в чате оркестратора — Claude, который ведёт задачу. Свой вариант окно примет текстом.</p>')
    body = ['<div class="ask-body">'] + [f'  <p class="note">{esc(s)}</p>' for s in data.get('answered', [])]
    for i, q in enumerate(qs, 1):
        if many:
            body.append(f'  <h3>Вопрос {q.get("n", i)}</h3>')
        body += ['  <p class="kind">Что происходит</p>', *('  ' + p for p in paras(q['about'])),
                 *('  ' + s for s in look(q, root)), '  <p class="kind">Варианты</p>', f'  <div class="opts" id="opts-{i}">']
        for letter, o in zip(LETTERS, q['options']):
            body += [f'    <div class="opt" id="opt-{i}-{letter}">', f'      <h4>{esc(o["title"])}</h4>',
                     f'      <p>{esc(o["text"])}</p>', '    </div>']
        body += ['  </div>', f'  <p><b>Рекомендация</b> — {esc(q["rec"])}</p>']
    return ['<section class="ask" id="ask">', *('  ' + s for s in top + ['</div>'] + body + ['</div>']), '</section>']


def main():
    if len(sys.argv) < 3 or sys.argv[2] not in [*STATE, 'new', 'link']:
        fail(2, 'вызов: page.py <задача> new|iteration|question|answer|stop|done|link [адрес], текст — со stdin')
    task, cmd = sys.argv[1], sys.argv[2]
    root = Path(git('rev-parse', '--show-toplevel'))
    log = Path(git('rev-parse', '--absolute-git-dir')) / 'agent-loop.log'
    task_file = root / 'docs' / 'tasks' / f'{task}.md'
    pages = root / 'my_local' / 'pages'
    file, links = pages / f'{task}.html', pages / 'links.md'
    rel = file.relative_to(root)
    if not task_file.exists():
        fail(2, f'нет таск-файла {task_file.relative_to(root)}')
    pages.mkdir(parents=True, exist_ok=True)
    known = links.read_text().splitlines() if links.exists() else []
    mine = f'- {task} — '

    if cmd == 'link':
        if len(sys.argv) < 4:
            fail(2, 'вызов: page.py <задача> link <адрес>')
        links.write_text('\n'.join([s for s in known if not s.startswith(mine)] + [mine + sys.argv[3]]) + '\n')
        print(f'{links.relative_to(root)}: адрес задачи {task} — {sys.argv[3]}')
        return

    text = sys.stdin.read() if not sys.stdin.isatty() else ''
    try:
        data = json.loads(text) if cmd in ('new', 'question', 'answer') else None
    except json.JSONDecodeError as e:
        fail(2, f'текст команды {cmd} — не JSON: {e}')
    now = datetime.now()

    if cmd == 'new':
        page = SKELETON.read_text()
        project = root.name
        status = read_task(task_file)[0]
        page = put(page, 'title', [f'<title>{esc(task)} · {esc(project)}</title>'])
        page = put(page, 'name', [f'<p class="eyebrow">Задача {esc(task)} · проект «{esc(project)}»</p>', f'<h1>{esc(data["title"])}</h1>'])
        page = put(page, 'lead', [esc(' '.join(data['lead'].split()))])
        goals = [f'  <li><strong>{esc(g["name"])}.</strong> {esc(g["text"])}</li>' for g in data['goals']]
        page = put(page, 'goals', ['<ul class="goals">', *goals, '</ul>'])
        notes = {s['n']: note_row(s['n'], s['note']) for s in data.get('stages', []) if s.get('note')}
        page = put(page, 'its-note', [])
        # вопросы и ответы прежней страницы с метками переходят на новую
        old = file.read_text() if file.exists() else ''
        page = put(page, 'qa', get(old, 'qa') if span(old, 'qa') else [NO_QA])
        page, _, _ = render_common(page, 'готово' if status == 'готово' else 'стоит', task_file, log, task, now, [], notes)
        file.write_text(page)
        what = 'страница заведена'
    else:
        page = file.read_text() if file.exists() else ''
        if any(span(page, m) is None for m in MARKS):
            fail(3, f'{rel}: страницы нет или в ней нет меток — сначала команда new, затем эта команда снова')
        # этап, появившийся в таск-файле после new, — пояснение к нему пишет оркестратор командой new
        shown = read_stages(page)[0]
        fresh = [str(n) for v in read_task(task_file)[2].values() for n, _ in v if n not in shown]
        if fresh:
            fail(3, f'{rel}: на странице нет этапа таск-файла {", ".join(fresh)} — сначала команда new, затем эта команда снова')
        before = page
        state = STATE[cmd]
        extra = paras(text) if cmd in ('stop', 'done') else []
        if cmd == 'answer':
            extra = ['<p>Ответ получен — он в разделе <a href="#qa">«Вопросы и ответы»</a>.</p>']
        page, cur, _ = render_common(page, state, task_file, log, task, now, extra)
        if cmd == 'iteration' and text.strip():
            page = put(page, 'its-note', [f'<p class="note">{esc(" ".join(text.split()))}</p>'])
        if cmd == 'question':
            page = put(page, 'toc-ask', ['<li><a href="#ask">Ждёт решения</a></li>'])
            page = put(page, 'ask', render_ask(data, root))
        if cmd == 'answer':
            items = []
            for a in data:
                who = 'оркестратора' if a['who'] == 'оркестратор' else 'пользователя'
                items += ['<details class="qa">',
                          f'  <summary><span class="meta"><span>{now:%Y-%m-%d %H:%M} · шаг «{esc(cur)}» · ответил {esc(a["who"])}</span></span>{esc(a["q"])}</summary>',
                          f'  <p><span class="kind">Ответ {who}</span> {esc(a["a"])}</p>', '</details>']
            old = get(page, 'qa')
            page = put(page, 'qa', items + ([] if old == [NO_QA] else old))
        file.write_text(page)
        changed = [m for m in MARKS if page[slice(*span(page, m)[:2])] != before[slice(*span(before, m)[:2])]]
        what = 'изменено: ' + ', '.join(changed) if changed else 'без изменений'
    url = next((s[len(mine):] for s in known if s.startswith(mine)), None)
    print(f'{rel}: {what}; ' + (f'адрес — {url}' if url else 'адреса нет — первая публикация'))


main()
