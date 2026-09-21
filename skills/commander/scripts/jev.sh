#!/usr/bin/env bash
# jev（TypeSafe の System One モデル）に型付きの判断を1回だけ問い合わせる薄いクライアント。
#   jev.sh <state.json> <questions.json>
#
# 標準出力に応答の `.answers` オブジェクト（JSON）だけを出す。呼び出し側は jq で読む。
#
# 終了コード:
#   0 = 応答を得た（stdout に answers の JSON）
#   2 = 呼び出し方の誤り（引数不足・ファイルが無い・JSON が壊れている）
#   3 = jev が使えない（APIキー未設定 / 通信失敗 / 非2xx / 応答が読めない）
#
# **3 は「判定できなかった」であって「判定が false だった」ではない。**
# 呼び出し側は 3 を受けたら必ず従来の経路（SKILL.md の散文基準による判断）へ落ちること。
# jev をこのスキルの必須依存にしない、というのがこのスクリプトの存在理由。
set -uo pipefail

die()  { printf 'jev: %s\n' "$*" >&2; exit 2; }
skip() { printf 'jev: %s\n' "$*" >&2; exit 3; }

[ $# -ge 2 ] || die "usage: jev.sh <state.json> <questions.json>"
STATE_F=$1; QUESTIONS_F=$2
[ -s "$STATE_F" ]     || die "state ファイルが無い/空: $STATE_F"
[ -s "$QUESTIONS_F" ] || die "questions ファイルが無い/空: $QUESTIONS_F"
command -v jq   >/dev/null 2>&1 || die "jq が無い"
command -v curl >/dev/null 2>&1 || die "curl が無い"
jq -e . "$STATE_F"     >/dev/null 2>&1 || die "state が JSON として読めない: $STATE_F"
jq -e . "$QUESTIONS_F" >/dev/null 2>&1 || die "questions が JSON として読めない: $QUESTIONS_F"

# APIキーが無ければ「使えない」で即座に抜ける。ここで落とさずに進むと、
# 呼び出し側が「判定 false」と取り違えて検収をすり抜けさせる危険がある。
[ -n "${TYPESAFE_API_KEY:-}" ] || skip "TYPESAFE_API_KEY が未設定なので従来経路へ落ちる"

API_BASE="${TYPESAFE_API_BASE:-https://api.typesafe.ai}"
MODEL="${COMMANDER_JEV_MODEL:-jev-latest}"
# 検収の途中で止まらないよう、1回あたりの上限を短く切る（既定30秒）。
TIMEOUT="${COMMANDER_JEV_TIMEOUT:-30}"

body=$(jq -n --slurpfile s "$STATE_F" --slurpfile q "$QUESTIONS_F" --arg m "$MODEL" \
  '{model: $m, state: $s[0], questions: $q[0]}') || die "リクエストボディを組み立てられない"

# 429 / 5xx は一過性なので指数バックオフで数回だけ再試行する。
# 4xx（401 のキー誤り等）は再試行しても変わらないので即座に「使えない」で抜ける。
attempt=0
while :; do
  resp=$(printf '%s' "$body" | curl -sS -m "$TIMEOUT" -w '\n%{http_code}' \
    -X POST "$API_BASE/v1/systemone" \
    -H "Authorization: Bearer $TYPESAFE_API_KEY" \
    -H 'Content-Type: application/json' \
    --data-binary @- 2>/dev/null)
  rc=$?
  code=$(printf '%s' "$resp" | tail -n1)
  payload=$(printf '%s' "$resp" | sed '$d')
  if [ "$rc" -ne 0 ]; then
    [ "$attempt" -lt 3 ] || skip "通信に失敗した（curl rc=${rc}）"
  elif [ "$code" = "200" ]; then
    break
  elif [ "$code" = "429" ] || [ "$code" = "529" ] || [ "${code:0:1}" = "5" ]; then
    [ "$attempt" -lt 3 ] || skip "再試行しても HTTP $code のままだった"
  else
    skip "HTTP ${code}（再試行しない）: $(printf '%s' "$payload" | head -c 200)"
  fi
  sleep $((2 ** attempt))
  attempt=$((attempt + 1))
done

# 応答に answers が無い形（仕様変更・エラーJSON）で呼び出し側を誤動作させない。
printf '%s' "$payload" | jq -e '.answers | objects' >/dev/null 2>&1 \
  || skip "応答に answers オブジェクトが無い: $(printf '%s' "$payload" | head -c 200)"
printf '%s' "$payload" | jq -c '.answers'
