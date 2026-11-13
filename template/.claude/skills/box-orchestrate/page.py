#!/usr/bin/env python3
# Скрипт страницы задачи оркестратора: правит файл my_local/pages/<задача>.html по меткам <!-- page:имя --> … <!-- /page:имя -->,
# всё вне меток — каркас примера examples/running.html; картинки вопроса — копиями в my_local/pages/<задача>/, кадры прогона
# в браузере — там же лентами с подписями сессии QA под кадрами и обложками WebP. Данные — таск-файл, журнал цикла, сценарии QA
# с их снимками экрана и подписями и текст оркестратора со stdin. Склейка кадров — библиотекой Pillow: она нужна, когда у задачи
# есть снимки прогона; подписи — шрифтом DejaVu Sans.
# Вызов из корня проекта: python3 .claude/skills/box-orchestrate/page.py <задача> <команда> [адрес] <<'EOF' … EOF
# Команды и форма текста — SKILL.md рядом, шаг «Страница задачи», текст question — questions.md; устройство страницы и метки — pages.md.
import functools
import hashlib
import html
import json
import mimetypes
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = None

SKELETON = Path(__file__).resolve().parent / 'examples' / 'running.html'
MARKS = ['title', 'name', 'meta', 'lead', 'where', 'updated', 'toc-ask', 'ask', 'goals', 'steps', 'now', 'toc-browser', 'browser',
         'its', 'its-note', 'qa']
NO_QA = '<p class="note">Вопросов пока не было.</p>'
# состояние страницы по команде; new берёт его из статуса задачи
STATE = {'iteration': 'идёт', 'question': 'ждёт решения', 'answer': 'стоит', 'stop': 'стоит', 'done': 'готово'}
# метки состояний: слово и класс цвета
RUN, WAIT, STAND = ('идёт', 'st-run'), ('ждёт решения', 'st-wait'), ('стоит', 'st-part')
FAIL, FAILED, PART = ('сбой', 'st-fail'), ('сбой', 'st-failed'), ('не закончен', 'st-part')
DONE, READY, PAST, TODO = ('сделано', 'st-done'), ('готово', 'st-done'), ('вопрос снят', 'st-past'), ('впереди', 'st-todo')
PASSED, MISSED = ('прошёл', 'st-done'), ('не прошёл', 'st-failed')
COUNT = {2: 'двух', 3: 'трёх', 4: 'четырёх'}
LETTERS = 'abcd'
ENGINE = 'движок — скрипт, который запускает Claude на шаги по очереди, —'
ORCH = 'оркестратор — Claude, который ведёт задачу, —'
# кусок ленты кадров — до 16 000 пикселей в высоту: WebP держит до 16 383
STRIP, QUALITY = 16000, 80
# записей в files одного ответа — до 255, остаток уходит со следующим событием
FILES = 255
PILLOW = ('нет библиотеки Pillow для склейки кадров прогона — установка: sudo apt install python3-pil, '
          'вне Debian и Ubuntu — python3 -m pip install Pillow; страница не обновлена')
# подпись под кадром ленты: шрифт с кириллицей — Pillow ищет файл в папках шрифтов системы; полоса — тёмная, текст — белый:
# на светлом сайте подпись видна отдельно от его интерфейса
FONT, BAND, INK = 'DejaVuSans.ttf', '#1b1f27', '#ffffff'
NOFONT = 'нет шрифта DejaVu Sans для подписей кадров прогона — установка: sudo apt install fonts-dejavu-core; страница не обновлена'


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


# сценарий QA — раздел «## <номер>. <название>» со строками «Из задачи:» или «Вне задачи», «Действия:», «Ожидается:», «Итог:»
SCENARIO = re.compile(r'^## (\d+)\. ([^\n]+)\n(.*?)(?=^## |\Z)', re.M | re.S)
FIELD = re.compile(r'^(Действия|Ожидается|Итог):[ \t]*(.*)$', re.M)
# снимок экрана прогона в my_local/qa/<задача>/ — <заход QA>-<сценарий>-<кадр>.<формат>
SHOT = re.compile(r'^(\d+)-(\d+)-(\d+)\.(png|jpe?g|webp)$', re.I)


def plain(s):
    return esc(s.replace('**', '').replace('`', '').strip())


def words(shot):
    # подпись кадра — файл <снимок>.txt рядом со снимком: что сессия QA сделала и что должно быть видно
    f = shot.with_suffix('.txt')
    return ' '.join(f.read_text(errors='replace').split()) if f.is_file() else ''


@functools.cache
def typeface(size):
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:
        fail(2, NOFONT)


def band(text, w):
    # полоса подписи под кадром ширины w: кегль — 1/50 ширины кадра, строки — по словам в ширину кадра с полями в полкегля;
    # ответ — шрифт, строки и высота полосы
    if not text:
        return None, [], 0
    size = max(w // 50, 12)
    face, lines = typeface(size), []
    for word in text.split():
        if lines and face.getlength(f'{lines[-1]} {word}') <= w - size:
            lines[-1] += ' ' + word
        else:
            lines.append(word)
    return face, lines, len(lines) * size * 13 // 10 + size


def stamp(part):
    # ключ файла — имена, размеры и время правки снимков, из которых он собран, и подписи кадров: новый или переснятый кадр
    # и новая подпись — новое имя, и публикация несёт новый файл, а прежний убирает уборка; у кадров без подписей ключ
    # тот же, что у лент до подписей, и такие ленты остаются прежними файлами
    return hashlib.sha1(''.join(f'{s.name} {s.stat().st_size} {s.stat().st_mtime_ns}{f" {t}" if t else ""}\n'
                                for s, _, t, _ in part).encode()).hexdigest()[:10]


def build(copy, part):
    # кадры друг под другом по левому краю, под подписанным кадром — полоса подписи во всю ширину куска, фон — белый;
    # запись через временный файл: команда, оборванная посреди склейки, оставляет только .part, и следующая команда
    # собирает кусок заново
    strip = Image.new('RGB', (max(w for _, (w, _), _, _ in part), sum(t for *_, t in part)), 'white')
    draw = ImageDraw.Draw(strip)
    y = 0
    for shot, size, text, tall in part:
        with Image.open(shot) as im:
            frame = im.convert('RGB')
        strip.paste(frame if frame.size == size else frame.resize(size), (0, y))
        face, lines, _ = band(text, size[0])
        if lines:
            draw.rectangle((0, y + size[1], strip.width, y + tall), fill=BAND)
            for i, line in enumerate(lines):
                draw.text((face.size // 2, y + size[1] + face.size // 2 + i * face.size * 13 // 10), line, font=face, fill=INK)
        y += tall
    copy.parent.mkdir(exist_ok=True)
    tmp = copy.with_name(copy.name + '.part')
    strip.save(tmp, 'WEBP', quality=QUALITY)
    tmp.replace(copy)


def ribbon(store, rnd, n, shots, frames):
    # кадры сценария по порядку с подписями — куски ленты до STRIP пикселей в высоту и обложка — последний кадр без подписи;
    # кадр — (снимок, размер в ленте, подпись, высота с полосой подписи), кадр с полосой выше STRIP уменьшается под STRIP;
    # файлы собираются один раз — по ключу в имени
    sized = []
    for shot in shots:
        with Image.open(shot) as im:
            w, h = im.size
        text = words(shot)
        room = STRIP - band(text, w)[2]
        size = (w * room // h, room) if h > room else (w, h)
        sized.append((shot, size, text, size[1] + band(text, size[0])[2]))
    parts = [[]]
    for frame in sized:
        if parts[-1] and sum(t for *_, t in parts[-1]) + frame[3] > STRIP:
            parts.append([])
        parts[-1].append(frame)
    out = [(store / f'qa-{rnd}-{n}-{i}-{stamp(p)}.webp', p) for i, p in enumerate(parts, 1)]
    last = [(*sized[-1][:2], '', sized[-1][1][1])]
    cover = store / f'qa-{rnd}-{n}-cover-{stamp(last)}.webp'
    for copy, part in [*out, (cover, last)]:
        if not copy.exists():
            build(copy, part)
        frames.add(copy)
    return cover, [copy for copy, _ in out]


def render_browser(root, task, stages, store, frames):
    # «Проверка в браузере»: сценарии QA с итогом и кадрами последнего захода; файла сценариев нет — раздела нет
    scen = root / 'docs' / 'qa' / f'{task}.md'
    if not scen.exists():
        return [], []
    # заход — номер из последней строки этапа «QA <K>» таск-файла: кадры прошлых заходов остаются только в папке снимков
    rounds = [int(m[1]) for v in stages.values() for _, title in v if (m := re.search(r'QA (\d+)$', title))]
    folder, shots = root / 'my_local' / 'qa' / task, {}
    if rounds and folder.is_dir():
        for f in folder.iterdir():
            if (m := SHOT.match(f.name)) and int(m[1]) == rounds[-1]:
                shots.setdefault(int(m[2]), []).append((int(m[3]), f))
    if shots and Image is None:
        fail(2, PILLOW)
    items, tally = [], {PASSED: 0, MISSED: 0, TODO: 0}
    for m in SCENARIO.finditer(scen.read_text()):
        n, f = int(m[1]), dict(FIELD.findall(m[3]))
        result = f.get('Итог', '').strip()
        st = PASSED if result.startswith('прошёл') else MISSED if result.startswith('не прошёл') else TODO
        tally[st] += 1
        mine = [shot for _, shot in sorted(shots.get(n, []))]
        # обложка — последний кадр сценария; куски ленты — в data-show через пробел, нажатие на обложку открывает их лентой
        if mine:
            face, strips = ribbon(store, rounds[-1], n, mine, frames)
            src = [html.escape(f'{store.name}/{c.name}') for c in strips]
            k = len(mine)
            cover = (f'<figure class="shot"><img src="{html.escape(f"{store.name}/{face.name}")}" data-show="{" ".join(src)}" '
                     f'alt="Сценарий {n}: последний из {k} {plural(k, "кадра", "кадров", "кадров")}" loading="lazy">'
                     f'<figcaption class="note">{k} {plural(k, "кадр", "кадра", "кадров")}</figcaption></figure>')
        else:
            cover = '<p class="note shot">Кадров нет</p>'
        text = [f'<h3>{n}. {plain(m[2])} {label(st)}</h3>']
        if re.search(r'^Вне задачи', m[3], re.M):
            text.append('<p class="note">Вне задачи: то, чего задача не обещала, — пользователь может так сломать приложение.</p>')
        if f.get('Действия'):
            text.append(f'<p class="note">Действия: {plain(f["Действия"])}</p>')
        if f.get('Ожидается'):
            text.append(f'<p>Ожидается: {plain(f["Ожидается"])}</p>')
        if st == MISSED:
            text.append(f'<p>Итог: {plain(result)}</p>')
        items += ['  <div class="sc">', f'    {cover}', '    <div>', *('      ' + s for s in text), '    </div>', '  </div>']
    total = sum(tally.values())
    head = ['<p class="note">Сессия проходит сценарии в приложении так, как прошёл бы пользователь, и снимает экран после каждого действия. '
            'Нажми на снимок — откроется лента кадров сценария: листай её прокруткой, кнопки «+» и «−» меняют размер.</p>',
            f'<p>Прошли — {tally[PASSED]}, не прошли — {tally[MISSED]}, впереди — {tally[TODO]} из {total} '
            f'{plural(total, "сценария", "сценариев", "сценариев")}.</p>']
    return (['<li><a href="#browser">Проверка в браузере</a></li>'],
            ['<section id="browser">', '  <h2>Проверка в браузере</h2>', *('  ' + s for s in head), *items, '</section>'])


def render_common(page, state, task_file, log, task, now, extra, root, store, frames, notes=None):
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
    toc, browser = render_browser(root, task, stages, store, frames)
    page = put(page, 'toc-browser', toc)
    page = put(page, 'browser', browser)
    if state != 'ждёт решения':
        page = put(page, 'toc-ask', [])
        page = put(page, 'ask', [])
    return page, cur, status


def look(q, root, store, copies, lost):
    # то, из чего выбирают, как его увидит читатель: текст на проверку и картинки файлами рядом со страницей
    out = []
    if q.get('quote'):
        out += ['  <blockquote>', *('    ' + p for p in paras(q['quote'])), '  </blockquote>']
    for im in q.get('images', []):
        # файл картинки — только внутри папки проекта: путь называет блокер, а страница уходит на claude.ai;
        # картинка без файла в папке проекта пропускается — вопрос уходит на страницу без неё, путь называет ответ скрипта
        path = (root / im['path']).resolve()
        kind = mimetypes.guess_type(path.name)[0]
        if not path.is_relative_to(root.resolve()) or not path.is_file() or not (kind or '').startswith('image/'):
            lost.append(im['path'])
            continue
        # копия — с именем по содержимому: та же картинка — тот же файл, новая — новый адрес
        body = path.read_bytes()
        copy = store / (hashlib.sha1(body).hexdigest()[:12] + path.suffix.lower())
        copies[copy] = body
        src = f'{store.name}/{copy.name}'
        # размер картинки — в атрибуте: страница, заведённая до стилей .look, держит старый каркас до new
        out += ['  <figure>', f'    <img src="{html.escape(src)}" alt="{html.escape(im["caption"])}" style="max-width: 100%; height: auto">',
                f'    <figcaption class="note">{esc(im["caption"])}</figcaption>', '  </figure>']
    return ['<p class="kind">Как это выглядит</p>', '<div class="look">', *out, '</div>'] if out else []


# признак стилей схемы мест в каркасе: страница, заведённая до них, получает их командой new
MAP_STYLE = '.map {'


def enter(s):
    # вход — текст со вставками команд в обратных кавычках, как в строке «Вход:» блокера
    return re.sub(r'`([^`]+)`', r'<code>\1</code>', esc(s))


def places(hands):
    # схема мест просьбы сделать руками: место — столбец в порядке первого шага места, шаг — плашка в строке сетки,
    # переход — строка перед шагом, сменившим место, со стрелкой между серединами столбцов и входом над ней;
    # над первым шагом — стрелка вниз со входом
    lanes = list(dict.fromkeys(h['where'] for h in hands))
    rows, prev, items = 1, None, []
    for n, h in enumerate(hands, 1):
        col = lanes.index(h['where']) + 1
        if col != prev:
            if not h.get('enter', '').strip():
                fail(2, f'текст команды question: у шага {n} просьбы сделать руками нет enter — '
                        f'{"первый шаг" if prev is None else "шаг сменил место"}, нужен вход в «{h["where"]}»; страница не обновлена')
            rows += 1
            lo, hi = min(prev or col, col), max(prev or col, col)
            way = 'down' if prev is None else ('right' if col > prev else 'left')
            items.append(f'<p class="go {way}" style="grid-column: {lo} / {hi + 1}; grid-row: {rows}; --span: {hi - lo + 1}">'
                         f'<span>{enter(h["enter"])}</span></p>')
        rows += 1
        items.append(f'<p class="stp" style="grid-column: {col}; grid-row: {rows}"><b>{n}</b> {esc(h["what"])}</p>')
        prev = col
    out = ['<p class="kind">Где что делать</p>', '<div class="scroll">', f'  <div class="map" style="--lanes: {len(lanes)}; --rows: {rows}">']
    out += [f'    <div class="lane" style="grid-column: {i}"></div>' for i in range(1, len(lanes) + 1)]
    out += [f'    <p class="lane-h" style="grid-column: {i}">{esc(w)}</p>' for i, w in enumerate(lanes, 1)]
    return out + ['    ' + s for s in items] + ['  </div>', '</div>',
                                                 '<p class="note">Как читать: столбец — место, номер — шаг в чате оркестратора по порядку, '
                                                 'стрелка — переход в другое место, над ней — как туда попасть.</p>']


def render_ask(data, root, store, copies, lost):
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
                 *('  ' + s for s in (places(q['hands']) if q.get('hands') else [])),
                 *('  ' + s for s in look(q, root, store, copies, lost)), '  <p class="kind">Варианты</p>', f'  <div class="opts" id="opts-{i}">']
        for letter, o in zip(LETTERS, q['options']):
            body += [f'    <div class="opt" id="opt-{i}-{letter}">', f'      <h4>{esc(o["title"])}</h4>',
                     f'      <p>{esc(o["text"])}</p>', '    </div>']
        body += ['  </div>', f'  <p><b>Рекомендация</b> — {esc(q["rec"])}</p>']
    return ['<section class="ask" id="ask">', *('  ' + s for s in top + ['</div>'] + body + ['</div>']), '</section>']


def main():
    if len(sys.argv) < 3 or sys.argv[2] not in [*STATE, 'new', 'link', 'sent']:
        fail(2, 'вызов: page.py <задача> new|iteration|question|answer|stop|done|link [адрес]|sent, текст — со stdin')
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
    url = next((s[len(mine):] for s in known if s.startswith(mine)), None)
    # файлы кадров прогона, которые уже дошли до страницы, и кадры последнего ответа скрипта — новые и убранные (null):
    # отметки по ним правит команда sent после удачной публикации
    ledger, sending = pages / task / 'sent.txt', pages / task / 'sending.json'
    sent = set(ledger.read_text().split()) if ledger.exists() else set()

    if cmd == 'link':
        if len(sys.argv) < 4:
            fail(2, 'вызов: page.py <задача> link <адрес>')
        links.write_text('\n'.join([s for s in known if not s.startswith(mine)] + [mine + sys.argv[3]]) + '\n')
        # новый адрес — новая страница без файлов прежней: отметки кадров снимаются, их несёт следующая публикация
        reset = bool(url and url != sys.argv[3] and sent)
        if reset:
            ledger.write_text('')
        print(f'{links.relative_to(root)}: адрес задачи {task} — {sys.argv[3]}' + ('; кадры прогона — со следующей публикацией' if reset else ''))
        return

    if cmd == 'sent':
        out = json.loads(sending.read_text()) if sending.exists() else {}
        added, gone = {k for k, v in out.items() if v}, {k for k, v in out.items() if v is None}
        if out:
            ledger.write_text(''.join(f'{s}\n' for s in sorted(sent - gone | added)))
            sending.write_text('{}')
        print(f'{ledger.relative_to(root)}: кадры прогона отмечены отправленными — {len(added)}, сняты с отметок — {len(gone)}')
        return

    text = sys.stdin.read() if not sys.stdin.isatty() else ''
    try:
        data = json.loads(text) if cmd in ('new', 'question', 'answer') else None
    except json.JSONDecodeError as e:
        fail(2, f'текст команды {cmd} — не JSON: {e}')
    now = datetime.now()
    copies, uploads, lost, frames = {}, {}, [], set()

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
        page, _, _ = render_common(page, 'готово' if status == 'готово' else 'стоит', task_file, log, task, now, [],
                                   root, pages / task, frames, notes)
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
        if cmd == 'question' and any(q.get('hands') for q in data['questions']) and MAP_STYLE not in page:
            fail(3, f'{rel}: в каркасе страницы нет стилей схемы мест — сначала команда new, затем эта команда снова')
        before = page
        state = STATE[cmd]
        extra = paras(text) if cmd in ('stop', 'done') else []
        if cmd == 'answer':
            extra = ['<p>Ответ получен — он в разделе <a href="#qa">«Вопросы и ответы»</a>.</p>']
        page, cur, _ = render_common(page, state, task_file, log, task, now, extra, root, pages / task, frames)
        if cmd == 'iteration' and text.strip():
            page = put(page, 'its-note', [f'<p class="note">{esc(" ".join(text.split()))}</p>'])
        if cmd == 'question':
            page = put(page, 'toc-ask', ['<li><a href="#ask">Ждёт решения</a></li>'])
            page = put(page, 'ask', render_ask(data, root, pages / task, copies, lost))
        if cmd == 'answer':
            items = []
            for a in data:
                who = 'оркестратора' if a['who'] == 'оркестратор' else 'пользователя'
                items += ['<details class="qa">',
                          f'  <summary><span class="meta"><span>{now:%Y-%m-%d %H:%M} · шаг «{esc(cur)}» · ответил {esc(a["who"])}</span></span>{esc(a["q"])}</summary>',
                          f'  <p><span class="kind">Ответ {who}</span> {esc(a["a"])}</p>', '</details>']
            old = get(page, 'qa')
            page = put(page, 'qa', items + ([] if old == [NO_QA] else old))
        # копии картинок — после разбора всего текста: ошибка в нём оставляет страницу и папку картинок прежними;
        # в ответ скрипта — все картинки вопроса: их несёт каждая публикация вопроса, и до страницы доходят
        # картинки сорвавшейся публикации и картинки, оставшиеся на прежнем адресе страницы
        for copy, body in copies.items():
            if not copy.exists():
                copy.parent.mkdir(exist_ok=True)
                copy.write_bytes(body)
            uploads[f'{copy.parent.name}/{copy.name}'] = str(copy.relative_to(root))
        file.write_text(page)
        changed = [m for m in MARKS if page[slice(*span(page, m)[:2])] != before[slice(*span(before, m)[:2])]]
        what = 'изменено: ' + ', '.join(changed) if changed else 'без изменений'
    # в публикацию события — файлы кадров без отметки sent и отмеченные файлы, которых страница больше не показывает, —
    # со значением null, публикация убирает их; убранные — вперёд новых: версия страницы держит до 511 файлов.
    # Файл уходит, пока публикация с ним не пройдёт, отправленные следующие публикации не несут
    out, rest = {}, 0
    if cmd != 'new':
        shown = {f'{c.parent.name}/{c.name}': str(c.relative_to(root)) for c in sorted(frames)}
        out = {s: None for s in sorted(sent - shown.keys())} | {k: v for k, v in shown.items() if k not in sent}
        room = FILES - len(uploads)
        out, rest = dict(list(out.items())[:room]), max(len(out) - room, 0)
        if out:
            sending.write_text(json.dumps(out, ensure_ascii=False))
        uploads.update(out)
    files = f'картинки — в files публикации: {json.dumps(uploads, ensure_ascii=False)}; ' if uploads else ''
    if out:
        files += 'после удачной публикации — команда sent; '
    if rest:
        # после done событий нет: остаток несут повторы done, которые оркестратор делает сам
        then = 'повтором done после публикации и sent' if cmd == 'done' else 'со следующим событием'
        files += f'ещё {rest} {plural(rest, "файл", "файла", "файлов")} кадров — {then}; '
    if lost:
        files += f'вопрос на странице без картинок — нет такого файла картинки в папке проекта: {", ".join(lost)}; '
    print(f'{rel}: {what}; {files}' + (f'адрес — {url}' if url else 'адреса нет — первая публикация'))


# текст оркестратора без нужного поля или с полем не того вида — ошибка вызова, файл страницы остаётся прежним
try:
    main()
except KeyError as e:
    fail(2, f'текст команды {sys.argv[2]}: нет поля {e}')
except (TypeError, AttributeError) as e:
    fail(2, f'текст команды {sys.argv[2]}: поле не того вида — {e}')
