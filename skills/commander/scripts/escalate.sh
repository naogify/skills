#!/usr/bin/env bash
# 検収を通った部下の成果について「司令官が決めて進めてよいか / 人間に上げるか」を判定する。
#   escalate.sh <mission-dir> <部下番号>
#
# SKILL.md Phase 6「検収を通った後の分岐」の表を、jev の noul 6問として書き直したもの。
# **散文の表を人が毎回読み直すと判断がぶれる**ので、閾値を数値で固定して再現性を持たせる。
#
# 終了コード:
#   0 = 司令官が決めて進めてよい
#   1 = 人間に上げる
#   3 = jev が使えなかった（従来どおり SKILL.md の表を読んで司令官が判断すること）
#
# **3 を「上げなくてよい」と読まないこと。** 判定できなかっただけで、判断は消えていない。
set -uo pipefail
export CMUX_QUIET=1

D="$(cd "$(dirname "$0")" && pwd)"
die() { printf 'escalate: %s\n' "$*" >&2; exit 2; }

[ $# -ge 2 ] || die "usage: escalate.sh <mission-dir> <部下番号>"
MISSION=$1; NO=$2
ROSTER="$MISSION/roster.jsonl"; WDIR="$MISSION/workers/$NO"
[ -s "$ROSTER" ] || die "roster が無い: $ROSTER"
row=$(jq -c --arg no "$NO" 'select((.no|tostring)==$no)' "$ROSTER" | tail -1)
[ -n "$row" ] || die "部下 $NO が roster にいない"
wt=$(printf '%s' "$row" | jq -r '.worktree // ""')
base=$(printf '%s' "$row" | jq -r '.base // ""')
task=$(printf '%s' "$row" | jq -r '.task // ""')

# 報告本文。新形式（STATUS.md）優先、無ければ旧形式に落ちる（verify.sh と同じ規則）。
REP="$WDIR/STATUS.md"; [ -s "$REP" ] || REP="$WDIR/REPORT.md"
[ -s "$REP" ] || die "報告ファイルが無い: $WDIR"

# 判断に使う材料を集める。diff は本文ではなく --stat だけを渡す
# （全文を state に入れるとトークンを食うだけで、判断の質は上がらない）。
diffstat=""
if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$base" ]; then
  diffstat=$(git -C "$wt" diff --stat "origin/$base...HEAD" 2>/dev/null | tail -30)
fi

tmp=$(mktemp -d) || die "mktemp 失敗"
trap 'rm -rf "$tmp"' EXIT

jq -n --arg task "$task" --rawfile report "$REP" --arg diffstat "$diffstat" \
  '{task: $task, report: $report, diffstat: $diffstat}' > "$tmp/state.json"

# SKILL.md の「人間に上げる」列をそのまま1問1答にしたもの。
# 質問は互いに独立に並列評価されるので、6問に分けても1問のときと応答時間はほぼ変わらない。
cat > "$tmp/questions.json" <<'JSON'
{
  "spec_ambiguous": { "type": "noul",
    "instructions": "この成果には仕様解釈が割れる論点が含まれている（どちらの挙動が正しいかを既存実装・規約から一意に決められない）" },
  "scope_moves": { "type": "noul",
    "instructions": "この成果はタスク本来の目的の外に出ている、または目的の一部を削っている" },
  "compat_risk": { "type": "noul",
    "instructions": "この成果は互換性・データ移行・権限モデルに影響する選択を含んでいる" },
  "one_way_door": { "type": "noul",
    "instructions": "この成果には取り消しが困難な変更が含まれている（公開APIの形、データ削除、HSTS preload など）" },
  "cost": { "type": "noul",
    "instructions": "この成果を進めるには、工数・課金・外部との合意が必要なほどのコストがかかる" },
  "needs_go": { "type": "noul",
    "instructions": "この成果を先に進めるには push / PR作成 / マージについて人間の GO が要る" }
}
JSON

answers=$(bash "$D/jev.sh" "$tmp/state.json" "$tmp/questions.json") || exit 3

# 閾値 0.4。0.5 ではなく低めに置くのは被害が非対称だから
# （上げすぎても人間が「推奨で」と一言返すだけだが、上げ損ねると勝手に進んで手戻りになる）。
# SKILL.md の「判断がつかないと思ったら上げる」を数値にしたもの。
THRESHOLD="${COMMANDER_ESCALATE_THRESHOLD:-0.4}"
printf '上げ判定: 部下%s（閾値 %s）\n' "$NO" "$THRESHOLD"
printf '%s' "$answers" | jq -r 'to_entries[] | "  \(.key)=\(.value.noul)"'

hits=$(printf '%s' "$answers" | jq -r --argjson t "$THRESHOLD" \
  'to_entries[] | select(.value.noul >= $t) | .key')
# 閾値には届かないが無視もしづらい帯（0.25〜閾値）は、上げはしないが一言残す。
grey=$(printf '%s' "$answers" | jq -r --argjson t "$THRESHOLD" \
  'to_entries[] | select(.value.noul >= 0.25 and .value.noul < $t) | .key')

if [ -n "$hits" ]; then
  printf '判定: 人間に上げる（該当: %s）\n' "$(printf '%s' "$hits" | tr '\n' ' ')"
  printf 'SKILL.md の形（①何が問題で ②自分はこう判断したくて ③何が不安か）で、★推奨付きの選択肢を添えて上げること。\n'
  exit 1
fi
[ -n "$grey" ] && printf 'NOTE 閾値未満だが確率が低くない項目: %s\n' "$(printf '%s' "$grey" | tr '\n' ' ')"
printf '判定: 司令官が決めて進めてよい\n'
exit 0
