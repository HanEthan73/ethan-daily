#!/usr/bin/env python3
"""
ETHAN MAIL — Gmail + 네이버 메일 통합 클라이언트

- 클라우드(Koyeb 등)에 올려 아이폰 홈 화면 앱처럼 사용. PC 불필요.
- IMAP으로 받은/보낸 메일을 가져와 SQLite에 저장하고 FTS5(trigram) 색인을 만든다.
- '탭' = 키워드 묶음(폰에 저장). 탭을 누르면 색인에서 키워드가 들어간 모든 메일을 모은다.
- SMTP로 계정별 발송(답장/전체답장/전달/첨부).

클라우드: 환경변수 APP_PASSWORD, GMAIL_EMAIL, GMAIL_APP_PASSWORD, NAVER_EMAIL, NAVER_APP_PASSWORD
로컬:     python app.py          (config.json 또는 환경변수)
데모:     python app.py --demo   (또는 환경변수 DEMO=1)
"""
import argparse
import base64
import hashlib
import hmac
import imaplib
import json
import mimetypes
import os
import re
import shutil
import smtplib
import sqlite3
import ssl
import threading
import time
import webbrowser
from datetime import timedelta
from email import message_from_bytes
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.utils import (formataddr, formatdate, getaddresses, make_msgid,
                         parsedate_to_datetime)
from html import escape, unescape
from urllib.parse import quote as urlquote

from flask import (Flask, Response, abort, g, jsonify, redirect, request,
                   send_from_directory, session)

BASE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE, "config.json")
EXAMPLE_PATH = os.path.join(BASE, "config.example.json")
ENV = os.environ
CLOUD = bool(ENV.get("PORT"))                 # Koyeb·Render 등은 PORT를 넣어 줌
APP_PASSWORD = ENV.get("APP_PASSWORD", "")
TEXT_LIMIT = 400_000                           # 본문은 앞 400KB까지만 받고, 큰 첨부는 열 때 받음

PRESETS = {
    "gmail": dict(imap_host="imap.gmail.com", imap_port=993,
                  smtp_host="smtp.gmail.com", smtp_port=465,
                  append_sent=False,          # Gmail은 SMTP 발송분을 보낸편지함에 자동 저장
                  sent_candidates=["[Gmail]/Sent Mail"], color="#E5483B", label="Gmail"),
    "naver": dict(imap_host="imap.naver.com", imap_port=993,
                  smtp_host="smtp.naver.com", smtp_port=465,
                  append_sent=True,           # 보낸메일함에 사본 저장 (중복되면 NAVER_APPEND_SENT=0)
                  sent_candidates=["Sent Messages", "보낸메일함"], color="#03A94D", label="네이버"),
}

CFG = {"accounts": [], "initial_sync_count": 300 if CLOUD else 500, "sync_interval_min": 5,
       "host": "127.0.0.1", "port": 5055}
ACCOUNTS = {}
DEMO = False
DB_PATH = os.path.join(BASE, "mail.db")

app = Flask(__name__, static_folder=os.path.join(BASE, "static"), static_url_path="/static")
app.config.update(
    MAX_CONTENT_LENGTH=30 * 1024 * 1024,
    SECRET_KEY=ENV.get("SECRET_KEY") or hashlib.sha256(("ethan-mail:" + APP_PASSWORD).encode()).hexdigest(),
    PERMANENT_SESSION_LIFETIME=timedelta(days=180),
    SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax", SESSION_COOKIE_SECURE=CLOUD,
)


# ───────────────────────── 설정 ─────────────────────────
def load_config():
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, encoding="utf-8") as f:
            CFG.update(json.load(f))
    elif not CLOUD and not ENV.get("GMAIL_EMAIL") and not ENV.get("NAVER_EMAIL") and os.path.exists(EXAMPLE_PATH):
        shutil.copy(EXAMPLE_PATH, CONFIG_PATH)
        print("※ config.json을 새로 만들었습니다. 메일 주소와 앱 비밀번호를 입력한 뒤 다시 실행하세요.")
        with open(CONFIG_PATH, encoding="utf-8") as f:
            CFG.update(json.load(f))
    # 환경변수 계정 (클라우드)
    env_accs = []
    for t in ("gmail", "naver"):
        e, p = ENV.get(f"{t.upper()}_EMAIL", "").strip(), ENV.get(f"{t.upper()}_APP_PASSWORD", "").strip()
        if e:
            a = {"id": t, "type": t, "email": e, "password": p, "name": ENV.get("MY_NAME", "")}
            if ENV.get(f"{t.upper()}_APPEND_SENT") is not None:
                a["append_sent"] = ENV[f"{t.upper()}_APPEND_SENT"] not in ("0", "false", "False")
            env_accs.append(a)
    if env_accs:
        CFG["accounts"] = env_accs
    if ENV.get("INITIAL_SYNC_COUNT"):
        CFG["initial_sync_count"] = int(ENV["INITIAL_SYNC_COUNT"])
    if ENV.get("SYNC_INTERVAL_MIN"):
        CFG["sync_interval_min"] = int(ENV["SYNC_INTERVAL_MIN"])
    for a in CFG.get("accounts", []):
        acc = dict(PRESETS.get(a.get("type", ""), {}))
        acc.update(a)
        acc.setdefault("id", a.get("type") or a["email"])
        acc.setdefault("label", acc["id"])
        acc.setdefault("color", "#64748B")
        acc["configured"] = bool(acc.get("email")) and bool(acc.get("password")) \
            and "여기에" not in acc.get("password", "") and "@" in acc.get("email", "")
        ACCOUNTS[acc["id"]] = acc


def demo_config():
    for t in ("gmail", "naver"):
        acc = dict(PRESETS[t])
        acc.update(id=t, type=t, email=f"ethan.demo@{'gmail.com' if t == 'gmail' else 'naver.com'}",
                   name="한의성", configured=True)
        ACCOUNTS[t] = acc


# ───────────────────────── DB ─────────────────────────
SCHEMA = """
CREATE TABLE IF NOT EXISTS messages(
  id INTEGER PRIMARY KEY,
  account TEXT, folder TEXT, uid INTEGER,
  message_id TEXT, in_reply_to TEXT, refs TEXT,
  subject TEXT, from_name TEXT, from_addr TEXT, to_addrs TEXT, cc_addrs TEXT,
  date_ts INTEGER, snippet TEXT, body_text TEXT, body_html TEXT,
  seen INTEGER DEFAULT 0, attachments TEXT, raw BLOB, partial INTEGER DEFAULT 0,
  UNIQUE(account, folder, uid));
CREATE INDEX IF NOT EXISTS idx_msg_date ON messages(date_ts DESC);
CREATE VIRTUAL TABLE IF NOT EXISTS mail_idx USING fts5(
  alltext, subject, sender, recipients, tokenize='trigram');
CREATE TABLE IF NOT EXISTS sync_state(
  account TEXT, folder TEXT, mailbox TEXT, uidvalidity INTEGER, last_uid INTEGER,
  PRIMARY KEY(account, folder));
"""


def connect():
    db = sqlite3.connect(DB_PATH, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    return db


def init_db():
    db = connect()
    db.executescript(SCHEMA)
    db.commit()
    db.close()


def get_db():
    if "db" not in g:
        g.db = connect()
    return g.db


@app.teardown_appcontext
def _close_db(_e):
    db = g.pop("db", None)
    if db:
        db.close()


# ───────────────────────── 접속 잠금 ─────────────────────────
FAILS = {}


def client_ip():
    return (request.headers.get("X-Forwarded-For", request.remote_addr or "") or "").split(",")[0].strip()


@app.before_request
def guard():
    p = request.path
    if p in ("/login", "/healthz", "/manifest.webmanifest") or p.startswith("/static/"):
        return None
    if not APP_PASSWORD:
        if CLOUD and not DEMO:
            return Response("APP_PASSWORD 환경변수(앱 접속 비밀번호)를 설정한 뒤 다시 배포하세요.", 503,
                            mimetype="text/plain; charset=utf-8")
        return None
    if session.get("ok"):
        return None
    if p.startswith("/api/"):
        return jsonify(error="로그인이 필요합니다"), 401
    return redirect("/login")


LOGIN_HTML = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="ETHAN MAIL"><meta name="theme-color" content="#17191D">
<link rel="apple-touch-icon" href="/static/icon-180.png"><link rel="manifest" href="/manifest.webmanifest">
<title>ETHAN MAIL</title><style>
body{margin:0;min-height:100dvh;display:grid;place-items:center;background:#17191D;color:#fff;
font-family:-apple-system,"Apple SD Gothic Neo","Malgun Gothic",system-ui,sans-serif}
form{width:min(320px,86vw);display:flex;flex-direction:column;gap:14px}
h1{font-size:22px;letter-spacing:.08em;margin:0 0 10px;text-align:center}h1 span{color:#6E8DFF}
input{font-size:17px;padding:14px;border-radius:12px;border:1px solid #33363d;background:#202227;color:#fff;outline:0}
button{font-size:17px;padding:14px;border-radius:12px;border:0;background:#2F5BEA;color:#fff;font-weight:600}
p{color:#ff8a7a;text-align:center;margin:0;font-size:14px;min-height:18px}</style></head><body>
<form method="post"><h1>ETHAN <span>MAIL</span></h1>
<input type="password" name="pw" placeholder="접속 비밀번호" autofocus autocomplete="current-password">
<button>열기</button><p>%s</p></form></body></html>"""


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        return LOGIN_HTML % ""
    ip = client_ip()
    n, until = FAILS.get(ip, (0, 0))
    if until > time.time():
        return LOGIN_HTML % "잠시 후 다시 시도하세요 (15분 잠금)", 429
    if APP_PASSWORD and hmac.compare_digest(request.form.get("pw", "").encode(), APP_PASSWORD.encode()):
        FAILS.pop(ip, None)
        session.permanent = True
        session["ok"] = True
        return redirect("/")
    time.sleep(1)
    n += 1
    FAILS[ip] = (n, time.time() + 900 if n >= 8 else 0)
    return LOGIN_HTML % "비밀번호가 맞지 않습니다", 401


@app.get("/logout")
def logout():
    session.clear()
    return redirect("/login")


@app.get("/healthz")
def healthz():
    return "ok"


@app.get("/manifest.webmanifest")
def manifest():
    return Response(json.dumps({
        "name": "ETHAN MAIL", "short_name": "ETHAN MAIL", "start_url": "/", "scope": "/",
        "display": "standalone", "background_color": "#F4F3EF", "theme_color": "#17191D",
        "icons": [{"src": "/static/icon-192.png", "sizes": "192x192", "type": "image/png"},
                  {"src": "/static/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"}],
    }, ensure_ascii=False), mimetype="application/manifest+json")


# ───────────────────────── 메일 파싱 ─────────────────────────
CHARSET_FIX = {"ks_c_5601-1987": "cp949", "ks_c_5601": "cp949", "euc-kr": "cp949",
               "euc_kr": "cp949", "x-windows-949": "cp949", "unknown-8bit": "utf-8"}


def dec(b, cs=None):
    if b is None:
        return ""
    if isinstance(b, str):
        return b
    tries = []
    if cs:
        cs = cs.lower().strip().strip('"')
        tries.append(CHARSET_FIX.get(cs, cs))
    tries += ["utf-8", "cp949"]
    for c in tries:
        try:
            return b.decode(c)
        except Exception:
            continue
    return b.decode("utf-8", "replace")


def dh(v):
    """헤더 디코딩 (=?UTF-8?B?..?=, EUC-KR, 인코딩 없는 UTF-8 모두 처리)"""
    if v is None:
        return ""
    s = str(v)
    if any("\udc80" <= ch <= "\udcff" for ch in s):
        s = dec(s.encode("ascii", "surrogateescape"))
    if "=?" in s:
        try:
            fixed = []
            for t, c in decode_header(s):
                if isinstance(t, bytes):
                    t = t.decode("raw-unicode-escape") if c is None else dec(t, c)
                fixed.append((t.encode("utf-8"), "utf-8"))
            s = str(make_header(fixed))
        except Exception:
            pass
    return re.sub(r"\s+", " ", s).strip()


def hget(msg, name):
    """원본 헤더 값 (8bit 문자는 surrogateescape 상태로 보존 → dh에서 복원)"""
    for k, v in getattr(msg, "_headers", []):
        if k.lower() == name.lower():
            return v
    return None


def html_to_text(h):
    h = re.sub(r"(?is)<(script|style|head)[^>]*>.*?</\1>", " ", h or "")
    h = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>|</li>", "\n", h)
    h = re.sub(r"<[^>]+>", " ", h)
    h = unescape(h)
    h = re.sub(r"[ \t ]+", " ", h)
    return re.sub(r"\n\s*\n+", "\n\n", h).strip()


def iter_attachments(msg):
    for part in msg.walk():
        if part.is_multipart():
            continue
        disp = (part.get("Content-Disposition") or "").lower()
        fn = part.get_filename()
        if fn or "attachment" in disp:
            yield part, (dh(fn) if fn else "첨부파일")


def est_size(part):
    p = part.get_payload()
    if not isinstance(p, str):
        return None
    enc = (part.get("Content-Transfer-Encoding") or "").lower()
    return int(len(re.sub(r"\s", "", p)) * 3 / 4) if enc == "base64" else len(p)


def parse_raw(raw, partial=False):
    msg = message_from_bytes(raw)
    text = html = None
    for part in msg.walk():
        if part.is_multipart():
            continue
        disp = (part.get("Content-Disposition") or "").lower()
        if part.get_filename() or "attachment" in disp:
            continue
        ctype = part.get_content_type()
        if ctype not in ("text/plain", "text/html"):
            continue
        try:
            payload = part.get_payload(decode=True)
        except Exception:
            payload = None
        if payload is None:
            continue
        body = dec(payload, part.get_content_charset())
        if ctype == "text/plain" and text is None:
            text = body
        elif ctype == "text/html" and html is None:
            html = body
    atts = [{"name": n, "type": p.get_content_type(), "size": None if partial else est_size(p)}
            for p, n in iter_attachments(msg)]
    plain = text if text else html_to_text(html or "")
    frm = getaddresses([dh(hget(msg, "From"))])
    from_name, from_addr = (frm[0] if frm else ("", ""))
    ts = None
    try:
        ts = int(parsedate_to_datetime(str(hget(msg, "Date"))).timestamp())
    except Exception:
        pass
    return dict(
        message_id=dh(hget(msg, "Message-ID")), in_reply_to=dh(hget(msg, "In-Reply-To")),
        refs=dh(hget(msg, "References")), subject=dh(hget(msg, "Subject")) or "(제목 없음)",
        from_name=from_name or from_addr, from_addr=from_addr,
        to_addrs=dh(hget(msg, "To")), cc_addrs=dh(hget(msg, "Cc")), date_ts=ts,
        snippet=re.sub(r"\s+", " ", plain)[:180], body_text=plain, body_html=html,
        attachments=json.dumps(atts, ensure_ascii=False))


def store_message(db, account, folder, uid, raw, seen, fallback_ts=None, partial=False):
    if db.execute("SELECT 1 FROM messages WHERE account=? AND folder=? AND uid=?",
                  (account, folder, uid)).fetchone():
        return False
    p = parse_raw(raw, partial)
    if not p["date_ts"]:
        p["date_ts"] = fallback_ts or int(time.time())
    cur = db.execute(
        """INSERT INTO messages(account,folder,uid,message_id,in_reply_to,refs,subject,from_name,
           from_addr,to_addrs,cc_addrs,date_ts,snippet,body_text,body_html,seen,attachments,raw,partial)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (account, folder, uid, p["message_id"], p["in_reply_to"], p["refs"], p["subject"],
         p["from_name"], p["from_addr"], p["to_addrs"], p["cc_addrs"], p["date_ts"], p["snippet"],
         p["body_text"], p["body_html"], 1 if seen else 0, p["attachments"], raw, 1 if partial else 0))
    sender = f"{p['from_name']} {p['from_addr']}"
    recips = f"{p['to_addrs']} {p['cc_addrs']}"
    db.execute("INSERT INTO mail_idx(rowid,alltext,subject,sender,recipients) VALUES(?,?,?,?,?)",
               (cur.lastrowid, f"{p['subject']}\n{sender}\n{recips}\n{(p['body_text'] or '')[:30000]}",
                p["subject"], sender, recips))
    return True


# ───────────────────────── IMAP ─────────────────────────
def imap_utf7_decode(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "&":
            j = s.find("-", i)
            if j == -1:
                out.append(s[i:]); break
            if j == i + 1:
                out.append("&")
            else:
                b = s[i + 1:j].replace(",", "/")
                b += "=" * (-len(b) % 4)
                try:
                    out.append(base64.b64decode(b).decode("utf-16-be"))
                except Exception:
                    out.append(s[i:j + 1])
            i = j + 1
        else:
            out.append(s[i]); i += 1
    return "".join(out)


def q(mailbox):
    return '"' + mailbox.replace("\\", "\\\\").replace('"', '\\"') + '"'


def imap_connect(acc):
    M = imaplib.IMAP4_SSL(acc["imap_host"], acc["imap_port"], ssl_context=ssl.create_default_context(),
                          timeout=60)
    M.login(acc["email"], acc["password"].replace(" ", ""))
    return M


def list_folders(M):
    typ, data = M.list()
    res = []
    for line in data or []:
        if not line:
            continue
        lit = None
        if isinstance(line, tuple):
            line, lit = line[0], line[1]
        s = line.decode("utf-8", "replace")
        m = re.match(r'\((?P<flags>[^)]*)\)\s+(?:"[^"]*"|NIL)\s*(?P<name>.*)$', s)
        if not m:
            continue
        name = lit.decode("utf-8", "replace") if lit is not None else m.group("name").strip()
        if name.startswith('"') and name.endswith('"'):
            name = name[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        res.append((m.group("flags"), name))
    return res


def find_sent(M, acc):
    folders = list_folders(M)
    for flags, name in folders:
        if "\\sent" in flags.lower():
            return name
    names = [n for _, n in folders]
    for c in acc.get("sent_candidates", []):
        if c in names:
            return c
    for n in names:
        d = imap_utf7_decode(n).lower()
        if "sent" in d or "보낸" in d:
            return n
    return None


def parse_fetch(data):
    """FETCH 응답을 메일 단위로 묶음 → [{'meta': bytes, 'lits': [(meta, literal), ...]}]"""
    msgs, cur = [], None
    for item in data or []:
        if isinstance(item, tuple):
            meta, lit = item[0], item[1]
            if cur is None or re.match(rb"^\d+ \(", meta):
                cur = {"meta": b"", "lits": []}
                msgs.append(cur)
            cur["meta"] += meta + b" "
            cur["lits"].append((meta, lit))
        elif isinstance(item, bytes) and cur is not None:
            cur["meta"] += item + b" "
    return msgs


def assemble(entry):
    """HEADER + TEXT 조각을 하나의 원문으로. 전체 BODY[]가 오면 그대로."""
    header = text = full = None
    for meta, lit in entry["lits"]:
        m = re.search(rb"(BODY\[[^\]]*\])(?:<\d+>)?\s*\{\d+\}\s*$", meta.upper())
        label = m.group(1) if m else b""
        if label == b"BODY[HEADER]":
            header = lit
        elif label == b"BODY[TEXT]":
            text = lit
        elif label in (b"BODY[]", b"RFC822"):
            full = lit
    if full is not None:
        return full
    return (header or b"") + (text or b"")


FETCH_ITEMS = f"(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.{TEXT_LIMIT}>)"


def sync_folder(M, acc, logical, mailbox, db):
    typ, _ = M.select(q(mailbox), readonly=True)
    if typ != "OK":
        return 0
    _, uv = M.response("UIDVALIDITY")
    uidvalidity = int(uv[0]) if uv and uv[0] else 0
    st = db.execute("SELECT uidvalidity,last_uid FROM sync_state WHERE account=? AND folder=?",
                    (acc["id"], logical)).fetchone()
    if st and st["uidvalidity"] != uidvalidity:  # 메일함이 재구성됨 → 다시 받기
        ids = [r[0] for r in db.execute("SELECT id FROM messages WHERE account=? AND folder=?",
                                         (acc["id"], logical))]
        db.executemany("DELETE FROM mail_idx WHERE rowid=?", [(i,) for i in ids])
        db.execute("DELETE FROM messages WHERE account=? AND folder=?", (acc["id"], logical))
        st = None
    last = st["last_uid"] if st else 0
    if not last:
        _, data = M.uid("SEARCH", "ALL")
        uids = [int(x) for x in (data[0] or b"").split()][-int(CFG.get("initial_sync_count", 300)):]
    else:
        _, data = M.uid("SEARCH", "UID", f"{last + 1}:*")
        uids = [int(x) for x in (data[0] or b"").split() if int(x) > last]
    have = {r[0] for r in db.execute("SELECT uid FROM messages WHERE account=? AND folder=?", (acc["id"], logical))}
    todo = sorted((u for u in uids if u not in have), reverse=True)  # 최신 메일부터
    new = 0
    for i in range(0, len(todo), 25):
        chunk = todo[i:i + 25]
        _, data = M.uid("FETCH", ",".join(map(str, chunk)), FETCH_ITEMS)
        for entry in parse_fetch(data):
            meta = entry["meta"].decode("utf-8", "replace")
            mu = re.search(r"UID (\d+)", meta)
            if not mu:
                continue
            raw = assemble(entry)
            ms = re.search(r"RFC822\.SIZE (\d+)", meta)
            partial = bool(ms) and int(ms.group(1)) > len(raw) + 64
            fts = None
            md = re.search(r'INTERNALDATE "([^"]+)"', meta)
            if md:
                try:
                    fts = int(time.mktime(imaplib.Internaldate2tuple(f'INTERNALDATE "{md.group(1)}"'.encode())))
                except Exception:
                    pass
            if store_message(db, acc["id"], logical, int(mu.group(1)), raw, "\\Seen" in meta, fts, partial):
                new += 1
        db.commit()
        SYNC["progress"] += 1
    top = max(uids + [last]) if uids else last
    db.execute("INSERT OR REPLACE INTO sync_state VALUES(?,?,?,?,?)",
               (acc["id"], logical, mailbox, uidvalidity, top))
    # 읽음 상태 맞추기 (웹메일·폰에서 읽은 것 반영)
    lo = db.execute("SELECT MIN(uid) FROM messages WHERE account=? AND folder=? AND uid>0",
                    (acc["id"], logical)).fetchone()[0]
    if lo:
        _, data = M.uid("FETCH", f"{lo}:*", "(UID FLAGS)")
        upd = []
        for line in data or []:
            if isinstance(line, tuple):
                line = line[0]
            s = (line or b"").decode("utf-8", "replace")
            mu = re.search(r"UID (\d+)", s)
            if mu:
                upd.append((1 if "\\Seen" in s else 0, acc["id"], logical, int(mu.group(1))))
        db.executemany("UPDATE messages SET seen=? WHERE account=? AND folder=? AND uid=?", upd)
    db.commit()
    return new


SYNC = {"running": False, "last": None, "errors": {}, "new": 0, "progress": 0}
SYNC_LOCK = threading.Lock()


def sync_account(acc, db):
    M = imap_connect(acc)
    try:
        n = sync_folder(M, acc, "inbox", "INBOX", db)
        sent = find_sent(M, acc)
        if sent:
            n += sync_folder(M, acc, "sent", sent, db)
        return n
    finally:
        try:
            M.logout()
        except Exception:
            pass


def run_sync():
    if DEMO:
        SYNC["last"] = int(time.time())
        return
    if not SYNC_LOCK.acquire(blocking=False):
        return
    SYNC["running"] = True
    db = connect()
    total = 0
    try:
        for acc in ACCOUNTS.values():
            if not acc["configured"]:
                SYNC["errors"][acc["id"]] = "메일 주소·앱 비밀번호가 설정되지 않았습니다"
                continue
            try:
                total += sync_account(acc, db)
                SYNC["errors"].pop(acc["id"], None)
            except imaplib.IMAP4.error as e:
                SYNC["errors"][acc["id"]] = f"로그인/IMAP 오류: {e} — IMAP 사용 설정과 앱 비밀번호를 확인하세요"
            except Exception as e:
                SYNC["errors"][acc["id"]] = f"{type(e).__name__}: {e}"
        if not ACCOUNTS:
            SYNC["errors"]["_"] = "등록된 메일 계정이 없습니다 (GMAIL_EMAIL / NAVER_EMAIL 환경변수 확인)"
        SYNC["new"] = total
        SYNC["last"] = int(time.time())
    finally:
        db.close()
        SYNC["running"] = False
        SYNC_LOCK.release()


def sync_loop():
    while True:
        run_sync()
        time.sleep(max(1, int(CFG.get("sync_interval_min", 5))) * 60)


def mailbox_of(acc_id, folder):
    db = connect()
    st = db.execute("SELECT mailbox FROM sync_state WHERE account=? AND folder=?", (acc_id, folder)).fetchone()
    db.close()
    return st["mailbox"] if st else None


def mark_seen_remote(acc_id, folder, uid, seen=True):
    acc = ACCOUNTS.get(acc_id)
    if DEMO or not acc or uid is None or uid <= 0:
        return
    try:
        mb = mailbox_of(acc_id, folder)
        if not mb:
            return
        M = imap_connect(acc)
        M.select(q(mb))
        M.uid("STORE", str(uid), "+FLAGS" if seen else "-FLAGS", "(\\Seen)")
        M.logout()
    except Exception as e:
        print("읽음 표시 실패:", e)


def full_raw(db, r):
    """큰 메일은 처음엔 본문만 받아 둠 → 첨부가 필요할 때 전체 원문을 받아 교체"""
    if not r["partial"] or DEMO or r["uid"] is None or r["uid"] <= 0:
        return r["raw"]
    acc, mb = ACCOUNTS.get(r["account"]), mailbox_of(r["account"], r["folder"])
    if not acc or not mb:
        return r["raw"]
    M = imap_connect(acc)
    try:
        M.select(q(mb), readonly=True)
        _, data = M.uid("FETCH", str(r["uid"]), "(UID BODY.PEEK[])")
        entries = parse_fetch(data)
        raw = assemble(entries[0]) if entries else None
    finally:
        try:
            M.logout()
        except Exception:
            pass
    if raw:
        p = parse_raw(raw)
        db.execute("UPDATE messages SET raw=?, partial=0, attachments=? WHERE id=?", (raw, p["attachments"], r["id"]))
        db.commit()
        return raw
    return r["raw"]


# ───────────────────────── 색인 검색 (탭) ─────────────────────────
FIELD = {"from": "sender", "보낸사람": "sender", "to": "recipients", "받는사람": "recipients",
         "subject": "subject", "제목": "subject"}


def split_terms(s):
    return [t.strip() for t in re.split(r"[,\n]", s or "") if t.strip()]


def term_clause(t):
    m = re.match(r"^(from|to|subject|보낸사람|받는사람|제목)\s*:\s*(.+)$", t, re.I)
    col, v = (FIELD[m.group(1).lower()], m.group(2).strip()) if m else ("alltext", t)
    return f"m.id IN (SELECT rowid FROM mail_idx WHERE {col} LIKE ?)", [f"%{v}%"]


def tab_where(keywords, exclude):
    where, params = [], []
    inc = [term_clause(t) for t in split_terms(keywords)]
    if inc:
        where.append("(" + " OR ".join(c for c, _ in inc) + ")")
        for _, p in inc:
            params += p
    else:
        where.append("0")
    exc = [term_clause(t) for t in split_terms(exclude)]
    if exc:
        where.append("NOT (" + " OR ".join(c for c, _ in exc) + ")")
        for _, p in exc:
            params += p
    return where, params


def build_where(kw="", ex="", query="", account="", folder="", tab=False):
    where, params = [], []
    if tab:
        w, p = tab_where(kw, ex)
        where += w; params += p
    for term in re.findall(r'"[^"]+"|\S+', query or ""):
        c, p = term_clause(term.strip('"'))
        where.append(c); params += p
    if account:
        where.append("m.account=?"); params.append(account)
    if folder in ("inbox", "sent"):
        where.append("m.folder=?"); params.append(folder)
    if folder == "unread":
        where.append("m.seen=0")
    return (" AND ".join(where) or "1"), params


def row_summary(r):
    return {"id": r["id"], "account": r["account"], "folder": r["folder"], "subject": r["subject"],
            "from_name": r["from_name"], "from_addr": r["from_addr"], "to": r["to_addrs"],
            "date": r["date_ts"], "snippet": r["snippet"], "seen": bool(r["seen"]),
            "has_att": r["attachments"] not in (None, "", "[]")}


# ───────────────────────── API ─────────────────────────
@app.route("/")
def index():
    resp = send_from_directory(app.static_folder, "index.html")
    resp.headers["Cache-Control"] = "no-cache"
    return resp


@app.get("/api/status")
def api_status():
    return jsonify(running=SYNC["running"], last=SYNC["last"], errors=SYNC["errors"], new=SYNC["new"],
                   progress=SYNC["progress"], demo=DEMO, auth=bool(APP_PASSWORD),
                   accounts=[{"id": a["id"], "label": a["label"], "email": a.get("email", ""),
                              "type": a.get("type", ""), "color": a["color"],
                              "configured": a["configured"]} for a in ACCOUNTS.values()])


@app.post("/api/sync")
def api_sync():
    threading.Thread(target=run_sync, daemon=True).start()
    return jsonify(ok=True)


@app.post("/api/tabcounts")
def api_tabcounts():
    d = request.get_json(force=True) or {}
    db = get_db()
    acc = d.get("account", "")
    aw, ap = (" AND m.account=?", [acc]) if acc else ("", [])
    r = db.execute(f"SELECT COUNT(*), COALESCE(SUM(seen=0 AND folder='inbox'),0) FROM messages m WHERE 1{aw}", ap).fetchone()
    out = {"all": {"count": r[0], "unread": r[1]}}
    for t in d.get("tabs", []):
        w, p = tab_where(t.get("keywords", ""), t.get("exclude", ""))
        r = db.execute(f"SELECT COUNT(*), COALESCE(SUM(m.seen=0),0) FROM messages m WHERE {' AND '.join(w)}{aw}",
                       p + ap).fetchone()
        out[str(t.get("id"))] = {"count": r[0], "unread": r[1]}
    return jsonify(out)


@app.post("/api/tabs/preview")
def api_tab_preview():
    d = request.get_json(force=True)
    db = get_db()
    w, p = tab_where(d.get("keywords", ""), d.get("exclude", ""))
    sql = " AND ".join(w)
    total = db.execute(f"SELECT COUNT(*) FROM messages m WHERE {sql}", p).fetchone()[0]
    rows = db.execute(f"SELECT subject, from_name FROM messages m WHERE {sql} ORDER BY date_ts DESC LIMIT 5", p)
    return jsonify(total=total, samples=[{"subject": r[0], "from": r[1]} for r in rows])


@app.get("/api/messages")
def api_messages():
    db = get_db()
    a = request.args
    where, params = build_where(a.get("kw", ""), a.get("ex", ""), a.get("q", ""), a.get("account", ""),
                                a.get("folder", ""), tab=a.get("tab", "all") != "all")
    limit = min(int(a.get("limit", 50)), 200)
    offset = int(a.get("offset", 0))
    total = db.execute(f"SELECT COUNT(*) FROM messages m WHERE {where}", params).fetchone()[0]
    rows = db.execute(f"""SELECT id,account,folder,subject,from_name,from_addr,to_addrs,date_ts,snippet,seen,attachments
                          FROM messages m WHERE {where} ORDER BY date_ts DESC LIMIT ? OFFSET ?""",
                      params + [limit, offset]).fetchall()
    return jsonify(total=total, items=[row_summary(r) for r in rows])


@app.post("/api/open/<int:mid>")
def api_open(mid):
    """메일 열기 + 읽음 처리 + 이 메일이 속한 탭 계산 (탭 목록은 폰이 보내 줌)"""
    db = get_db()
    r = db.execute("SELECT * FROM messages WHERE id=?", (mid,)).fetchone()
    if not r:
        abort(404)
    if not r["seen"]:
        db.execute("UPDATE messages SET seen=1 WHERE id=?", (mid,))
        db.commit()
        threading.Thread(target=mark_seen_remote, args=(r["account"], r["folder"], r["uid"]), daemon=True).start()
    tabs = []
    for t in (request.get_json(silent=True) or {}).get("tabs", []):
        w, p = tab_where(t.get("keywords", ""), t.get("exclude", ""))
        if db.execute(f"SELECT 1 FROM messages m WHERE m.id=? AND {' AND '.join(w)}", [mid] + p).fetchone():
            tabs.append(t.get("id"))
    d = row_summary(r)
    d.update(cc=r["cc_addrs"], body_text=r["body_text"], body_html=r["body_html"],
             attachments=json.loads(r["attachments"] or "[]"), message_id=r["message_id"],
             refs=r["refs"], tabs=tabs, seen=True, partial=bool(r["partial"]))
    return jsonify(d)


@app.post("/api/messages/<int:mid>/unread")
def api_unread(mid):
    db = get_db()
    r = db.execute("SELECT account, folder, uid FROM messages WHERE id=?", (mid,)).fetchone()
    db.execute("UPDATE messages SET seen=0 WHERE id=?", (mid,))
    db.commit()
    if r:
        threading.Thread(target=mark_seen_remote, args=(r["account"], r["folder"], r["uid"], False), daemon=True).start()
    return jsonify(ok=True)


@app.get("/api/messages/<int:mid>/attachment/<int:n>")
def api_attachment(mid, n):
    db = get_db()
    r = db.execute("SELECT * FROM messages WHERE id=?", (mid,)).fetchone()
    if not r:
        abort(404)
    raw = full_raw(db, r)
    for i, (part, name) in enumerate(iter_attachments(message_from_bytes(raw))):
        if i == n:
            return Response(part.get_payload(decode=True) or b"", mimetype=part.get_content_type(),
                            headers={"Content-Disposition": f"attachment; filename*=UTF-8''{urlquote(name)}"})
    abort(404)


@app.post("/api/send")
def api_send():
    f = request.form
    acc = ACCOUNTS.get(f.get("account"))
    if not acc:
        return jsonify(ok=False, error="보낼 계정을 선택하세요"), 400
    to, cc, bcc = f.get("to", ""), f.get("cc", ""), f.get("bcc", "")
    rcpts = [a for _, a in getaddresses([x for x in (to, cc, bcc) if x.strip()]) if "@" in a]
    if not rcpts:
        return jsonify(ok=False, error="받는 사람 주소를 확인하세요"), 400
    msg = EmailMessage()
    msg["From"] = formataddr((acc.get("name", ""), acc["email"]))
    msg["To"] = to
    if cc:
        msg["Cc"] = cc
    msg["Subject"] = f.get("subject", "")
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=acc["email"].split("@")[-1])
    if f.get("in_reply_to"):
        msg["In-Reply-To"] = f["in_reply_to"]
        msg["References"] = (f.get("references", "") + " " + f["in_reply_to"]).strip()
    msg.set_content(f.get("body", ""))
    for up in request.files.getlist("files"):
        data = up.read()
        ctype = up.mimetype or mimetypes.guess_type(up.filename)[0] or "application/octet-stream"
        mt, st = ctype.split("/", 1) if "/" in ctype else ("application", "octet-stream")
        msg.add_attachment(data, maintype=mt, subtype=st, filename=up.filename)
    if f.get("forward_id"):  # 전달: 원본 첨부 포함
        db = get_db()
        r = db.execute("SELECT * FROM messages WHERE id=?", (f["forward_id"],)).fetchone()
        if r:
            for part, name in iter_attachments(message_from_bytes(full_raw(db, r))):
                mt, st = part.get_content_type().split("/", 1)
                msg.add_attachment(part.get_payload(decode=True) or b"", maintype=mt, subtype=st, filename=name)

    if DEMO:
        db = get_db()
        store_message(db, acc["id"], "sent", -int(time.time() * 1000) % 2_000_000_000 * -1 - 1, msg.as_bytes(), True)
        db.commit()
        return jsonify(ok=True, demo=True)
    try:
        ctx = ssl.create_default_context()
        if int(acc["smtp_port"]) == 465:
            s = smtplib.SMTP_SSL(acc["smtp_host"], 465, context=ctx, timeout=30)
        else:
            s = smtplib.SMTP(acc["smtp_host"], int(acc["smtp_port"]), timeout=30)
            s.starttls(context=ctx)
        s.login(acc["email"], acc["password"].replace(" ", ""))
        s.send_message(msg, to_addrs=rcpts)
        s.quit()
    except Exception as e:
        return jsonify(ok=False, error=f"발송 실패: {e}"), 500
    if acc.get("append_sent"):
        try:
            M = imap_connect(acc)
            sent = find_sent(M, acc)
            if sent:
                M.append(q(sent), "(\\Seen)", imaplib.Time2Internaldate(time.time()), msg.as_bytes())
            M.logout()
        except Exception as e:
            print("보낸메일함 저장 실패:", e)
    threading.Thread(target=run_sync, daemon=True).start()
    return jsonify(ok=True)


# ───────────────────────── 데모 데이터 ─────────────────────────
def seed_demo():
    db = connect()
    if db.execute("SELECT COUNT(*) FROM messages").fetchone()[0]:
        db.close(); return
    now = int(time.time())
    H = 3600
    samples = [
        ("naver", "inbox", "사람인", "noreply@saramin.co.kr", "[사람인] 의성님께 맞는 채용공고 12건 — 전력전자·BMS 연구직",
         "현대모비스 전동화 연구(경력 3~7년), 삼성SDI BMS 알고리즘, LG에너지솔루션 셀 제어 등 의성님 이력서와 일치하는 공고입니다.", 2, False),
        ("gmail", "inbox", "Wanted", "notice@wanted.co.kr", "면접 일정 안내 — 42dot 파워트레인 제어 엔지니어",
         "안녕하세요 한의성님, 1차 기술면접 일정을 11월 13일(목) 14:00로 안내드립니다. 화상 링크는 하루 전 발송됩니다.", 5, False),
        ("gmail", "inbox", "Coupang", "order@coupang.com", "주문 완료: 오실로스코프 프로브 외 1건",
         "결제 금액 128,400원. 로켓배송으로 내일(월) 도착 예정입니다.", 7, True),
        ("naver", "inbox", "CJ대한통운", "no-reply@cjlogistics.com", "[CJ대한통운] 택배 배송 출발 안내",
         "고객님의 상품이 배송 출발하였습니다. 운송장번호 6823-****-1120, 오늘 18시 전 도착 예정.", 9, False),
        ("gmail", "inbox", "Sarah Kim (LinkedIn)", "inmail-hit-reply@linkedin.com", "Opportunity: Senior Power Electronics Engineer (OBC/DCDC)",
         "Hi Ethan, I'm a recruiter at a Tier-1 EV supplier in California. Your CLLC resonant converter experience looks like a great fit for our hiring needs.", 20, True),
        ("naver", "inbox", "잡코리아", "jobkorea@jobkorea.co.kr", "[잡코리아] 입사지원 결과 — 서류 합격을 축하드립니다",
         "한국전력기술 R&D 전력변환 직무 서류전형에 합격하셨습니다. 인적성 검사 안내는 별도 메일로 드립니다.", 30, False),
        ("gmail", "inbox", "IEEE PELS", "newsletter@ieee-pels.org", "PELS Newsletter: Bidirectional OBC topology review",
         "This month: CLLC vs. DAB for 11 kW bidirectional on-board chargers, GaN adoption trends, and APEC 2027 call for papers.", 34, True),
        ("naver", "inbox", "신한카드", "alert@shinhancard.com", "[신한카드] 승인 안내 54,000원 (일시불)",
         "11/07 19:42 교보문고 승인 54,000원. 누적 사용금액 812,330원.", 40, True),
        ("gmail", "inbox", "팀장 이준호", "junho.lee@example-company.com", "OBC 효율 시험 결과 공유 (11kW, 800V)",
         "의성님, 어제 측정한 CLLC 효율 맵 정리해서 월요일 회의 때 공유 부탁드립니다. 경부하 구간 ZVS 손실 분석도 같이요.", 46, False),
        ("naver", "inbox", "원티드", "notice@wanted.co.kr", "포지션 제안이 도착했어요 — 배터리 제어 시니어",
         "스타트업 '볼트랩'에서 의성님께 포지션을 제안했습니다. 연봉 협의 가능, 판교 근무. 수락 여부를 7일 안에 알려주세요.", 60, True),
        ("gmail", "inbox", "Tesla", "no-reply@tesla.com", "Your service appointment is confirmed",
         "Your Tesla service appointment on Nov 15 at 10:00 AM is confirmed. Mobile service will arrive at your location.", 70, True),
        ("naver", "inbox", "토익위원회", "toeic@ybm.co.kr", "[TOEIC Speaking] 성적 발표 안내",
         "11월 2일 시험 성적이 발표되었습니다. 홈페이지에서 확인하세요.", 90, True),
        ("gmail", "inbox", "Remember", "career@rememberapp.co.kr", "[리멤버] 헤드헌터가 의성님 프로필을 열람했습니다",
         "자동차 전장 분야 헤드헌터 2명이 최근 일주일간 프로필을 열람했습니다. 커리어 제안을 받아보세요.", 110, True),
        ("naver", "inbox", "11번가", "help@11st.co.kr", "주문하신 상품이 출고되었습니다",
         "주문번호 2026110612 상품이 출고되었습니다. 배송 조회는 앱에서 가능합니다.", 130, True),
        ("gmail", "sent", "한의성", "ethan.demo@gmail.com", "Re: 면접 일정 안내 — 42dot 파워트레인 제어 엔지니어",
         "안녕하세요, 일정 확인했습니다. 11월 13일 14시 면접 참석하겠습니다. 감사합니다. 한의성 드림", 4, True),
        ("naver", "sent", "한의성", "ethan.demo@naver.com", "[입사지원] 한의성 — 전력변환 R&D 지원서 제출",
         "안녕하세요. 첨부와 같이 입사지원서와 포트폴리오를 제출합니다. 검토 부탁드립니다.", 200, True),
    ]
    for i, (acc, folder, name, addr, subj, body, hours, seen) in enumerate(samples):
        m = EmailMessage()
        me = ACCOUNTS[acc]["email"]
        if folder == "sent":
            m["From"] = formataddr(("한의성", me)); m["To"] = "recruit@example.co.kr"
        else:
            m["From"] = formataddr((name, addr)); m["To"] = me
        m["Subject"] = subj
        m["Date"] = formatdate(now - hours * H, localtime=True)
        m["Message-ID"] = make_msgid(domain="demo.local")
        m.set_content(body)
        m.add_alternative(f"<div style='font-family:sans-serif;line-height:1.7'><p>{escape(body)}</p>"
                          f"<p style='color:#888;font-size:12px'>— {escape(name)}</p></div>", subtype="html")
        if "지원서" in subj:
            m.add_attachment(b"%PDF-1.4 demo", maintype="application", subtype="pdf", filename="한의성_이력서.pdf")
        store_message(db, acc, folder, i + 1, m.as_bytes(), seen)
    db.commit()
    db.close()


# ───────────────────────── 실행 ─────────────────────────
def main():
    global DEMO, DB_PATH
    ap = argparse.ArgumentParser(description="ETHAN MAIL")
    ap.add_argument("--demo", action="store_true", help="샘플 메일로 체험 (계정 불필요)")
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    DEMO = args.demo or ENV.get("DEMO") in ("1", "true")
    if DEMO:
        DB_PATH = os.path.join(BASE, "demo.db")
        demo_config()
    else:
        load_config()
    init_db()
    if DEMO:
        seed_demo()
    threading.Thread(target=sync_loop, daemon=True).start()
    host = "0.0.0.0" if CLOUD else CFG.get("host", "127.0.0.1")
    port = int(ENV.get("PORT") or CFG.get("port", 5055))
    print(f"\n  ETHAN MAIL 실행 중 → port {port}{'  (데모 모드)' if DEMO else ''}\n", flush=True)
    if not CLOUD and not args.no_browser:
        threading.Timer(1.2, lambda: webbrowser.open(f"http://127.0.0.1:{port}")).start()
    try:
        from waitress import serve
        serve(app, host=host, port=port, threads=8)
    except ImportError:
        app.run(host=host, port=port, threaded=True, debug=False)


if __name__ == "__main__":
    main()
