# loongson-debugger 的 emacs / projmenu 开发环境（脱敏版）

`loongson-debugger` 包里带了一套 Emacs 配置，核心是一个叫 `projmenu` 的工程菜单系统：
在**工程目录**里放一个 `.menu.org`（Org 语法），Emacs 菜单栏就按它的标题层级自动生成菜单；
点菜单项即可执行编译、shell、终端、gdb、loongson-debugger 等命令。

这套配置已经把 **gdb** 和 **loongson debugger（EJTAG）** 两组菜单做成默认模板，
并且 `myhelp` 菜单里有两份帮助文档（安装说明与使用说明）。本仓库把这些内容抽出来、
**脱敏**后独立发布，便于复用与学习。

> 来源：`loongson-debugger` 分享包中 `20261119/emacsd.tar.xz` 的 `.emacs.d/mytool/projmenu/`
> 与说明文档。菜单引擎 `.proj.el` 保持原样（已确认无个人信息），所有路径/IP/账号已替换为占位符。

## 菜单思想

1. **工程目录里创建 `.menu.org`**：每个 Org 一级标题是一个顶层菜单，二级标题是子菜单，
   标题下的正文就是命令。
2. **修改后立即生效**：编辑 `.menu.org` 后点 `projmenu ▸ Reload Menu` 重建菜单，无需重启 Emacs。
3. **`projmenu` 是常驻公共菜单**：切换工程、生成/打开菜单、项目文件、项目历史等管理功能都在这里，
   不与 `.menu.org` 定义的业务菜单混在一起。
4. **默认模板已集成 gdb 与 loongson-debugger**：`.menu.org` 通过 `#+INCLUDE` 引入 `.tools.org`，
   里面定义了 `gdb`、`debugger`、`msys2`、`myhelp` 等菜单。
5. **两个帮助文档**：`myhelp ▸ project menu install help` 打开安装说明，
   `myhelp ▸ project menu usage help` 打开完整使用说明。

## 文件清单

| 路径 | 作用 |
|---|---|
| `elisp/.proj.el` | 菜单引擎：解析 `.menu.org` → 生成菜单栏、项目切换、状态持久化 |
| `templates/.menu.org` | 默认菜单模板（build + `#+INCLUDE` 引入 `.tools.org`） |
| `templates/.tools.org` | gdb / debugger / msys2 / myhelp 菜单定义（脱敏后） |
| `help/readme.txt` | 帮助文档一：安装与 emacsd 部署说明 |
| `help/proj-readme.org` | 帮助文档二：`.menu.org` 语法、执行模式、变量展开、菜单结构、快捷键 |
| `scripts/install-menu.sh` | 把上述文件装进 `~/.emacs.d` |

## 安装

### 1. 准备 Emacs 与原始配置

Emacs 可用发行版包安装（如 `apt install emacs`）；无 root 时可 `apt download emacs` 后
`dpkg-deb -x` 到用户目录，再设置 `EMACSLOADPATH` / `EMACSDATA` / `EMACS_EXEC_PATH`。
完整配置（含 evil、elpa 包）来自原包 `emacsd.tar.xz`，解压到用户家目录得到 `~/.emacs.d`。

### 2. 安装/更新菜单层

```sh
sh scripts/install-menu.sh
```

脚本会把模板、帮助文档和菜单引擎复制到 `~/.emacs.d`，并在 `init.el` 末尾追加加载代码
（已存在则不重复追加）。注意：`.proj.el` 依赖 `evil`，必须保证 `evil` 先加载。

### 3. 在工程里生成菜单

打开工程后：

- `projmenu ▸ Change project` 选工程目录；
- `projmenu ▸ generate/open menu` 在工程根目录生成 `.menu.org` 并打开；
- 按需要编辑，再 `projmenu ▸ Reload Menu`。

### 4. 配置 gdb 与 loongson-debugger

- `gdb ▸ set gdb tool`：选择 `gdb` 可执行文件（模板默认 `/usr/bin/gdb`，可按实际改）；
- `gdb ▸ select elffile`：选择带符号的 ELF；
- `gdb ▸ run gdb`：以 `gdb -i=mi` 启动，并填入配置的 server 端口。

- `debugger ▸ set debugger tool`：选择 `la_dbg_tool_usb`（LA64）、`la32_dbg_tool_usb`（LA32）
  或 `ejtag_debug_usb`（MIPS）的绝对路径；
- `debugger ▸ start debugger` 直接开命令行，或 `start debugger server` + `start debugger client`
  通过 telnet 交互；
- 普通用户访问 USB 调试器需把 `90-jtag.rules` 放到 `/etc/udev/rules.d/`。

## `.menu.org` 速查

```org
* build                      ; 顶层菜单
** compile                   ; 菜单项
 make -j8                    ; 命令正文
** compile in shell #shell   ; 用 shell buffer 执行
 make
* Debug #gdb                 ; 用 gdb 模式执行
 ./firmware.elf
* 工具
** 打开笔记 #eval            ; 直接 eval Elisp
(find-file "notes.org")
```

执行模式写在标题注释里：`#shell` / `#term` / `#pterm` / `#xterm` / `#eshell` /
`#gdb` / `#eval` 等；属性 `#+workdir:`、`#+path:`、`#+rawcmd:` 控制工作目录、PATH 与变量展开。
详见 `help/proj-readme.org`。

## 脱敏对照

| 原内容 | 替换为 |
|---|---|
| 个人家目录下的 gdb 绝对路径 | `/usr/bin/gdb` |
| 调试器安装绝对路径 | `/path/to/la_dbg_tool_usb` |
| 内网 IP / 远程登录地址 | `<NFS_HOST>` / `<user>@<host>` |
| 模型平台注册邀请码 | 去掉邀请参数，只留公开注册页 |

仓库中不含任何主机名、IP、账号、令牌或私有路径。

## 验证菜单是否生效

在无图形的终端里也能检查菜单树是否构建成功（把 `~/.emacs.d` 换成你的配置目录）：

```sh
emacs --batch -l ~/.emacs.d/init.el --eval '
(progn
  (setq proj-el-dir (file-truename "."))
  (ls-proj-genmenu)
  (proj-rebuild-menu-from-org)
  (princ (format "MENUS=%S\n" (sort (hash-table-keys proj--menu-item-lists) (quote string<)))))'
```

预期能看到 `projmenu`、`myhelp`、`build`、`gdb`、`debugger`、`msys2` 等菜单名。

## 许可与致谢

菜单引擎与模板来自 loongson-debugger 随包发布的 Emacs 配置；帮助文档为社区整理版本。
本仓库仅做脱敏与重新组织，不声明对上游代码的著作权。
