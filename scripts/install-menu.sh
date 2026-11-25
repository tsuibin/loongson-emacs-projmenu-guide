#!/bin/sh
# 把 projmenu 菜单层与帮助文档安装到 ~/.emacs.d（不覆盖已有的同名自定义文件的备份）。
set -eu

ROOT="${EMACS_DIR:-$HOME/.emacs.d}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$ROOT/mytool/projmenu" "$ROOT/help"

for pair in \
    "elisp/.proj.el:mytool/projmenu/.proj.el" \
    "templates/.menu.org:mytool/projmenu/.menu.org" \
    "templates/.tools.org:mytool/projmenu/.tools.org" \
    "help/readme.txt:readme.txt" \
    "help/proj-readme.org:proj-readme.org"
do
    src="$HERE/${pair%%:*}"
    dst="$ROOT/${pair#*:}"
    if [ -f "$dst" ]; then
        cp -f "$dst" "$dst.bak"
    fi
    cp -f "$src" "$dst"
    echo "installed: $dst"
done

INIT="$ROOT/init.el"
LOAD_LINE='(let ((p (expand-file-name "./mytool/projmenu/.proj.el" user-emacs-directory))) (when (file-exists-p p) (load p)))'
if [ -f "$INIT" ]; then
    if grep -Fq 'mytool/projmenu/.proj.el' "$INIT"; then
        echo "init.el 已有加载语句，跳过"
    else
        printf '\n%s\n' "$LOAD_LINE" >> "$INIT"
        echo "已向 init.el 追加加载语句（请确认 evil 在此之前加载）"
    fi
else
    printf ';; 请先准备好 evil / org，再加载 projmenu\n%s\n' "$LOAD_LINE" > "$INIT"
    echo "已创建 init.el（需自行配置 evil / org）"
fi
