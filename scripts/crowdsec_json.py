"""cscli の JSON 出力を読むための共通処理（report.sh から import する）。

cscli の出力形は版によって「alert の配列（decisions を入れ子で持つ）」と
「decision の配列」の両方があり得る。どちらで来ても同じ形で読めるようにしてある。
ここが崩れると遮断が 0 件として扱われ、静かに何も記録されなくなるので、
形が読めなかったときは例外にせず None を返し、呼び出し側が「問い合わせ失敗」を出す。
"""

import datetime
import json
import re

# シナリオ名は人間には意味不明なので日本語ラベルで出す。
# 完全一致で引き、無ければ前方一致、それも無ければシナリオ名をそのまま出す。
EXACT = {
    "crowdsecurity/http-probing": "脆弱性スキャン（404 連発）",
    "crowdsecurity/http-crawl-non_statics": "高速クロール",
    "crowdsecurity/http-bad-user-agent": "不審な User-Agent",
    "crowdsecurity/http-path-traversal-probing": "パストラバーサル探索",
    "crowdsecurity/http-sensitive-files": "機密ファイル探索（.env / .git）",
    "crowdsecurity/http-sqli-probing": "SQL インジェクション探索",
    "crowdsecurity/http-xss-probing": "XSS 探索",
    "crowdsecurity/http-backdoors-attempts": "バックドア設置の試行",
    "crowdsecurity/http-open-proxy": "オープンプロキシ探し",
    "crowdsecurity/http-generic-bf": "認証の総当たり",
    "crowdsecurity/http-w00tw00t": "既知スキャナ（w00tw00t）",
    "crowdsecurity/ssh-bf": "SSH ログイン総当たり",
    "crowdsecurity/ssh-slow-bf": "SSH ログイン総当たり（低速）",
}

PREFIX = [
    ("crowdsecurity/CVE-", "既知の脆弱性を突く要求"),
    ("crowdsecurity/http-cve", "既知の脆弱性を突く要求"),
    ("crowdsecurity/", "CrowdSec 既定ルール"),
]


def label_of(scenario: str) -> str:
    if not scenario:
        return "不明"
    if scenario in EXACT:
        return EXACT[scenario]
    # 手動遮断は "manual 'ban' from 'xxx'" のような文になる
    if scenario.startswith("manual"):
        return "手動遮断"
    # 対応表に無いものは、日本語の分類にシナリオ名を添えて出す。
    # 名前が分からないと閾値を調整しに行けない
    for prefix, label in PREFIX:
        if scenario.startswith(prefix):
            return f"{label}（{scenario}）"
    return scenario


def load(path):
    """cscli -o json の出力を読む。空・非 JSON なら None（= 問い合わせ失敗）。"""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read().strip()
    except OSError:
        return None
    if not text:
        return None
    try:
        data = json.loads(text)
    except ValueError:
        # 0 件のとき、版によっては JSON ではなく "No active decisions" を出す。
        # これを問い合わせ失敗として扱うと、平穏な日に 5 分ごとの同期が失敗し続ける
        if "no active" in text.lower():
            return []
        return None
    if data is None:
        return []
    return data if isinstance(data, list) else []


def iter_decisions(payload):
    """(alert, decision) を順に返す。alert 入れ子・decision 平坦のどちらでも読む。

    scope が Ip / Range 以外（Country 等）のものは、console 側が IP 前提なので飛ばす。
    """
    for item in payload or []:
        if not isinstance(item, dict):
            continue
        nested = item.get("decisions")
        pairs = [(item, d) for d in nested if isinstance(d, dict)] if isinstance(nested, list) else [(item, item)]
        for alert, decision in pairs:
            scope = str(decision.get("scope") or "Ip").lower()
            if scope not in ("ip", "range"):
                continue
            if not decision.get("value"):
                continue
            yield alert, decision


# 単位は長いものから並べる。"12ms" を "12m" + 余り "s" と読んでしまい、
# ミリ秒が分になって失効時刻が桁違いになるため（正規表現の選択は先頭一致優先）
DURATION = re.compile(r"(-?\d+(?:\.\d+)?)(ms|us|µs|ns|h|m|s)")

UNIT_SECONDS = {
    "h": 3600.0,
    "m": 60.0,
    "s": 1.0,
    "ms": 0.001,
    "us": 0.000001,
    "µs": 0.000001,
    "ns": 0.000000001,
}


def duration_seconds(text):
    """Go の duration 文字列（"3h59m12.3s" 等）を秒に。読めなければ None。"""
    if not text:
        return None
    negative = str(text).lstrip().startswith("-")
    total = 0.0
    found = False
    for value, unit in DURATION.findall(str(text)):
        total += abs(float(value)) * UNIT_SECONDS[unit]
        found = True
    if not found:
        return None
    return -total if negative else total


def expires_at(decision, now=None):
    """decision の残り時間から失効時刻（ISO8601・UTC）を作る。読めなければ None。

    cscli の duration は「今から何秒残っているか」なので、同期のたびに数秒ぶれる。
    console 側は expires_at を更新列として持っているので上書きされて問題ない。
    """
    seconds = duration_seconds(decision.get("duration"))
    if seconds is None:
        return None
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return (now + datetime.timedelta(seconds=seconds)).replace(microsecond=0).isoformat()


def banned_at(alert):
    """遮断の開始時刻。alert の作成時刻を使う（同じ遮断なら毎回同じ値になる）。"""
    for key in ("created_at", "start_at"):
        value = alert.get(key)
        if isinstance(value, str) and value:
            return value
    return None
