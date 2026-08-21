#!/usr/bin/env python3
"""指令書のプレースホルダを安全に置換する。

  render_prompt.py <ファイル> <KEY=VALUE>...

read-modify-write のワンライナー（`open(p,"w").write(open(p).read().replace(...))`）は
`open(p,"w")` が先に評価されてファイルを truncate するため、内側の `read()` が空を返し、
指令書ごと消える事故になる。このスクリプトは:

  1. ファイルを**先に全部読み**、読み終わってから置換・書き込みに入る
  2. 置換は `<KEY>` の完全一致のみ（部分一致・正規表現ではない）
  3. 書き込みは同じディレクトリの tempfile に行い、`os.replace()` で原子的に差し替える
     （書き込み中に落ちても原本は壊れない）
  4. 元ファイルが空・存在しない場合は**何も書かずに** exit 1

置換後、`<ALL_CAPS>` 形式（英大文字・数字・アンダースコアのみ）で残っているプレースホルダの
個数を標準出力に出す。0 なら exit 0、1 つでも残っていれば exit 1（渡し忘れの検出）。
`<部下名>` や `<owner/repo>` のような、テンプレート中の説明用の山括弧（日本語・小文字混じり）は
この判定に含めない。含めると `new-task.sh` が生成する報告プロトコル文中の説明用プレースホルダ
（`<最後の項目>` 等。これは司令官ではなく部下自身が埋めるもの）まで「未解決」扱いになり、
正しく埋めたはずの指令書が常に exit 1 になってしまうため。
"""
import os
import re
import sys
import tempfile

PLACEHOLDER_RE = re.compile(r"<([A-Z][A-Z0-9_]*)>")


def die(msg):
    print(f"render_prompt: {msg}", file=sys.stderr)
    sys.exit(1)


def main(argv):
    if len(argv) < 2:
        die('usage: render_prompt.py <file> <KEY=VALUE>...')
    path = argv[1]
    pairs = argv[2:]

    if not os.path.isfile(path):
        die(f"ファイルが無い: {path}")

    # ここで読み終える。書き込みに入るのはこの後だけ（read → write の順序をコードで強制する）。
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
    except UnicodeDecodeError as e:
        die(f"UTF-8 として読めない: {path} ({e})")

    if not content:
        die(f"ファイルが空: {path}（何もせず終了する）")

    replacements = {}
    for pair in pairs:
        if "=" not in pair:
            die(f"KEY=VALUE の形式ではない: {pair}")
        key, value = pair.split("=", 1)
        if not key:
            die(f"KEY が空: {pair}")
        replacements[key] = value

    for key, value in replacements.items():
        content = content.replace(f"<{key}>", value)

    directory = os.path.dirname(os.path.abspath(path)) or "."
    tmp_fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".render_prompt.", suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    remaining = PLACEHOLDER_RE.findall(content)
    print(len(remaining))
    if remaining:
        for name in sorted(set(remaining)):
            print(f"  残っているプレースホルダ: <{name}>", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
