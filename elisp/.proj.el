;; -*- lexical-binding: t -*-
;;; proj.el --- Org-driven project menu builder  -*- lexical-binding: t -*-

;; 功能：
;; - 从 .menu.org 解析出菜单树，自动生成 menu-bar 菜单
;; - 支持多行 cmd、eval 模式多行 Elisp
;; - 支持属性继承（workdir / rawcmd / path）
;; - 支持 .menu.org 第一行的 `#+proj:' 属性指定项目文件根目录
;;   （未指定则用 .menu.org 所在目录）；`#+proj:' 后可以有多个目录，
;;   用 proj-multi-dir-separator（默认 ; 或 ,）分隔，支持 tramp 路径
;;   （如 /ssh:host:/path、/plink:host:/path）。
;;   Project files / 状态保存、恢复均以这些目录为准；
;;   Projects 仍按 .menu.org 所在目录归组
;; - Modes 子菜单：CUA / Evil / Debug-on-Error 复选框
;; - History 子菜单：最近 10 个项目，一键切换，持久化保存
;; - 支持文件开头 #+begin_src elisp … #+end_src，在解析菜单前执行
;;   （**按文件**执行）
;; - 支持 #+INCLUDE: other.org，把被包含文件的内容在解析前就地展开
;; - Project files 子菜单：动态列出项目文件根目录下已打开文件
;; - Projects 子菜单：按 .menu.org 所在目录归组所有已打开 buffer
;; - proj-call-menu-item：通过菜单标题 / 菜单项路径以命令方式调用菜单项
;; - 项目文件状态持久化：key 用 .menu.org 所在目录，value 是
;;   `#+proj:' 指定目录下的文件列表；写盘前先读磁盘，只替换当前
;;   project 的 key，再原子写回，不覆盖其它 Emacs 写入的其它项目状态
;; - 公共项（Modes / History / Project files / Projects / 各菜单管理项）
;;   构成独立的顶层菜单 `projmenu'，**无条件显示**
;; - .menu.org 里的每个顶层标题各自成为独立菜单；如果没有任何
;;   菜单项（或缺失），额外显示 `myhelp' 帮助菜单

;;; Code:

(require 'easymenu)
(require 'org)
(require 'cl-lib)

;;; ---------- Custom ----------

(defgroup proj nil
  "Project menu builder."
  :group 'tools)

(defcustom proj-history nil
  "最近使用过的项目目录列表，最近的在最前。"
  :type '(repeat directory)
  :group 'proj)

(defcustom proj-history-max 10
  "History 菜单保留的最大项目数量。"
  :type 'integer
  :group 'proj)

(defcustom proj-edit-before-run t
  "edit cmdline before run"
  :type 'boolean
  :group 'proj)

(defcustom proj-multi-dir-separator "[;,]"
  "`#+proj:' 行里多个目录之间的分隔符（正则）。
默认同时支持 `;' 与 `,'。特意不使用 `path-separator'（Unix 上为 `:'），
以避免切断 tramp 路径 `/ssh:host:/path'、`/plink:host:/path' 中的冒号。"
  :type 'regexp
  :group 'proj)

;;; ---------- 状态 ----------

(defvar proj-el-dir
  (or (and buffer-file-name
           (locate-dominating-file buffer-file-name ".menu.org"))
      (locate-dominating-file default-directory ".menu.org")
      default-directory)
  "当前项目根目录（.menu.org 所在目录）。
用作 History / 状态 key / Projects 分组归依。")

(defvar proj-project-roots nil
  "当前项目的文件根目录列表。
由 .menu.org 第一行的 `#+proj:' 属性指定（可多个）；未指定时为
\(`proj-el-dir')。
Project files 子菜单、状态保存/恢复用的文件扫描根目录。")

(defvar proj-menu--symbols nil
  "本包创建的 menu-bar 符号列表，用于清理旧绑定。")

(defvar proj--menu-item-lists (make-hash-table :test 'equal)
  "按顶层菜单标题缓存最终 items 列表（源顺序，供补全使用）。")

(defvar current-menu-org-file ""
  "current .menu.org file")

(defun proj-history-add (dir)
  "把 DIR 加入项目历史，去重并限制长度。
历史发生变化时用 `customize-save-variable' 持久化。"
  (when (and dir (stringp dir))
    (let* ((new (cons dir (delete dir (copy-sequence proj-history))))
           (new (if (> (length new) proj-history-max)
                    (butlast new (- (length new) proj-history-max))
                  new)))
      (unless (equal new proj-history)
        (setq proj-history new)
        (customize-save-variable 'proj-history proj-history)))))

(defun proj-history-clear ()
  "清空项目历史并重建菜单。"
  (interactive)
  (when proj-history
    (setq proj-history nil)
    (customize-save-variable 'proj-history proj-history))
  (proj-rebuild-menu-from-org))

;;; ---------- `#+proj:' 属性读取 ----------

(defun proj--read-proj-attr (org-file)
  "从 ORG-FILE 第一行读取 `#+proj:' 属性，返回绝对目录列表（每个带尾斜杠）。
第一行不是 `#+proj:'、为空或文件不可读时返回 nil。
支持 `#+proj:dir1;dir2' 或 `#+proj:dir1,dir2'（分隔由
`proj-multi-dir-separator' 决定）。分隔符没有选用 `path-separator'
（Unix 是 `:'），是为了保留 tramp 路径 `/ssh:host:/path' 里的冒号。
为处理速度只读取文件开头的一小段，不加载整个 .menu.org。"
  (let ((file (expand-file-name org-file)))
    (when (file-regular-p file)
      (with-temp-buffer
        (insert-file-contents file nil 0 4096)
        (goto-char (point-min))
        (let ((case-fold-search t))
          (when (looking-at "^[ \t]*#\\+proj:[ \t]*\\(.*\\)$")
            (let ((v (string-trim (match-string 1))))
              (unless (string= v "")
                (let ((dirs nil)
                      (base (file-name-directory file)))
                  (dolist (s (split-string v proj-multi-dir-separator t))
                    (let ((s (string-trim s)))
                      (unless (string= s "")
                        (push (file-name-as-directory
                               (expand-file-name s base))
                              dirs))))
                  (nreverse dirs))))))))))

(defun proj--proj-dir-attr (proj-dir)
  "返回 PROJ-DIR（含 .menu.org 的项目目录）对应的项目文件根目录列表。
由 .menu.org 第一行的 `#+proj:' 指定；未指定时返回
\(PROJ-DIR)，均为带尾斜杠的绝对路径。"
  (or (proj--read-proj-attr (expand-file-name ".menu.org" proj-dir))
      (list (file-name-as-directory (expand-file-name proj-dir)))))

;;; ---------- 项目文件状态持久化 ----------

(defvar proj-state-file
  (expand-file-name ".proj-state.el" user-emacs-directory)
  "项目打开文件状态的持久化保存路径。")

;; 不在内存里缓存整个状态。写盘前先读磁盘，只替换当前 project 的 key；
;; 恢复时也实时读盘。避免多个 Emacs 先后运行时互相覆盖其它项目状态。

(defun proj--state-key (root)
  "规范化 ROOT 作为状态 alist 的 key：绝对路径 + 尾斜杠。"
  (file-name-as-directory (expand-file-name root)))

(defun proj--state-delete-key (key alist)
  "从 ALIST 中删除所有 key 等于 KEY（equal 比较）的条目。"
  (let (out)
    (dolist (cell alist (nreverse out))
      (unless (equal (car cell) key)
        (push cell out)))))

(defun proj--read-state-file ()
  "从 `proj-state-file' 读取状态 alist。
返回 (KEY . FILES) 列表，KEY 规范化为绝对路径 + 尾斜杠；
同一 key 只保留第一条。文件不存在或读取失败返回 nil。"
  (let ((alist nil))
    (when (file-exists-p proj-state-file)
      (with-temp-buffer
        (insert-file-contents proj-state-file)
        (goto-char (point-min))
        (condition-case err
            (let ((read-eval nil))
              (setq alist (read (current-buffer))))
          (error
           (message "[proj.el] load state error: %s" err)
           (setq alist nil)))))
    (let ((seen (make-hash-table :test 'equal))
          (out  nil))
      (dolist (cell alist)
        (when (and (consp cell) (stringp (car cell)))
          (let ((k (proj--state-key (car cell))))
            (unless (gethash k seen)
              (puthash k t seen)
              (push (cons k (cdr cell)) out)))))
      (nreverse out))))

(defun proj--write-state-file (alist)
  "把 ALIST 写入 `proj-state-file'。
用临时文件 + rename 原子替换，减少写到一半被中断的风险。"
  (let* ((dir (file-name-directory proj-state-file))
         (tmp (make-temp-file (expand-file-name ".proj-state-" dir)
                              nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (let ((print-length nil)
                  (print-level nil))
              (prin1 alist (current-buffer))))
          (rename-file tmp proj-state-file t))
      (when (file-exists-p tmp)
        (ignore-errors (delete-file tmp))))))

(defun proj--update-state (key files)
  "读取磁盘上的当前状态，把 KEY 对应条目替换为 FILES，再写回。
只修改 KEY，不覆盖其它 key（可能是其它 Emacs 写入的项目状态）。"
  (let* ((key   (proj--state-key key))
         (alist (proj--read-state-file))
         (alist (cons (cons key files)
                      (proj--state-delete-key key alist))))
    (proj--write-state-file alist)))

(defun proj--file-in-dirs-p (file dirs)
  "FILE 是否属于 DIRS（目录列表）中的任一个。
用前缀字符串比较，避免不必要的 tramp 远端访问。"
  (let ((file (if (stringp file) file "")))
    (cl-some (lambda (dir)
               (let ((dir (file-name-as-directory
                           (expand-file-name dir))))
                 (or (string= dir file)
                     (string-prefix-p dir file))))
             dirs)))

(defun proj--snapshot-project-files (roots)
  "返回 ROOTS 下当前已打开文件的绝对路径列表。
ROOTS 可以是单个目录字符串或目录列表。不包含 TAGS / tags 文件。"
  (let* ((dirs (if (listp roots) roots (list roots)))
         (files nil))
    (dolist (buf (buffer-list))
      (let* ((file (buffer-file-name buf))
             (name (and file (file-name-nondirectory file))))
        (when (and file
                   (not (member name '("TAGS" "tags")))
                   (proj--file-in-dirs-p file dirs))
          (push (expand-file-name file) files))))
    (nreverse files)))

(defun proj--remember-project-files (proj-dir &optional no-save)
  "保存 PROJ-DIR（.menu.org 所在目录）对应的项目文件状态。
文件扫描根为 .menu.org 第一行 `#+proj:' 指定的目录（可多个），
未指定则为 PROJ-DIR 本身。
写盘前会先读取磁盘现有状态，只更新 PROJ-DIR 对应的 key，
不会覆盖其它项目。
NO-SAVE 非 nil 时不写盘，仅返回 (KEY . FILES)。"
  (when (and proj-dir (stringp proj-dir))
    (let* ((key   (proj--state-key proj-dir))
           (scan  (proj--proj-dir-attr proj-dir))
           (files (proj--snapshot-project-files scan)))
      (unless no-save
        (proj--update-state key files))
      (cons key files))))

(defun proj--remember-all-projects ()
  "保存所有已知工程的文件状态（Emacs 退出时使用）。
每个工程单独读-改-写，尽量不覆盖其它 Emacs 写入的其它项目状态。"
  (dolist (cell (proj--project-buffer-groups))
    (when (car cell)
      (proj--remember-project-files (car cell))))
  (when proj-el-dir
    (proj--remember-project-files proj-el-dir)))

(defun proj--on-kill-emacs ()
  "退出 Emacs 前保存所有工程打开文件。"
  (condition-case err
      (proj--remember-all-projects)
    (error (message "[proj.el] save state on exit failed: %s" err))))

(defun proj--restore-project-files (root)
  "打开 ROOT 下上次保存的已打开文件（不切换窗口）。
每次从磁盘读取最新状态，不依赖内存缓存。"
  (let* ((key   (proj--state-key root))
         (alist (proj--read-state-file))
         (files (cdr (assoc key alist)))
         (opened 0))
    (dolist (file files)
      (when (file-exists-p file)
        (condition-case err
            (progn
              (find-file-noselect file t)
              (setq opened (1+ opened)))
          (error
           (message "[proj.el] restore %s: %s" file err)))))
    (when (> opened 0)
      (message "[proj.el] restored %d file(s) for %s" opened root))))

;; >>> FIX: 记录本进程已恢复过打开文件的工程，避免每次重建菜单重复恢复
;; （用户手动关闭文件后，Reload Menu 不应又把文件打开；
;;  同时保证 rebuild 是「先恢复、后快照保存」，不会把磁盘状态覆盖为空）。
(defvar proj--restored-root nil
  "最近一次已恢复打开文件的工程目录（`proj--state-key' 规范化后）。
避免每次重建菜单都重新打开已被用户关闭的文件。")

(defun proj--restore-once (root)
  "若 ROOT 尚未恢复过，则从磁盘恢复其保存的已打开文件。"
  (when (and root (stringp root))
    (let ((key (proj--state-key root)))
      (unless (equal key proj--restored-root)
        (setq proj--restored-root key)
        (proj--restore-project-files root)))))

(defun proj--switch-to-project (root)
  "切换当前项目到 ROOT，恢复上次打开的文件，并重建菜单。
切换前先保存当前项目的打开文件列表，保证切走后还能切回恢复。
打开 ROOT 前清理必要缓存。"
  (when root
    (when (and proj-el-dir
               (not (equal (expand-file-name proj-el-dir)
                           (expand-file-name root))))
      (proj--remember-project-files proj-el-dir))
    ;; 打开 proj 前清理必要缓存
    (clrhash proj--menu-item-lists)
    (setq proj-el-dir root)
    (setq proj-project-roots (proj--proj-dir-attr root))
    (proj--restore-project-files root)
    ;; >>> FIX: 显式切换时恢复过，同步标记，避免 rebuild 重复恢复
    (setq proj--restored-root (proj--state-key root))
    (proj-rebuild-menu-from-org)))

;;; ---------- 项目切换 / 文件操作 ----------

(defun ls-proj-title ()
  "返回当前 proj 根目录字符串，用作菜单 label。"
  proj-el-dir)

(defun ls-proj-set ()
  "交互式选择项目根目录并重建菜单。"
  (interactive)
  (let ((dir (read-directory-name "Directory for proj: " proj-el-dir)))
    (proj--switch-to-project dir)))

(defun ls-proj-openfile ()
  "打开项目内的文件。"
  (interactive)
  (find-file (read-file-name "filename in proj: " proj-el-dir)))

(defun ls-proj-defmenu ()
  "切换到默认菜单模板。"
  (interactive)
  (proj-rebuild-menu-from-org
   (expand-file-name "./mytool/projmenu/.menu.org" user-emacs-directory)))

(defun ls-proj-genmenu (&optional openonly)
  "在项目根目录生成 / 打开 .menu.org。"
  (interactive)
  (unless proj-el-dir (ls-proj-set))
  (let ((newmenu (expand-file-name ".menu.org" proj-el-dir))
        (defmenu (expand-file-name "./mytool/projmenu/.menu.org"
                                   user-emacs-directory)))
    (unless openonly
      (when (condition-case nil
		(progn
		  (let ((last-nonmenu-event '(mouse-1)))
		    (copy-file defmenu newmenu 1))
		  t)
	      (file-error nil))           ; 选 n 时返回 nil，跳过 rebuild
	(proj-rebuild-menu-from-org newmenu)))
    (find-file newmenu)))

(defun ls-proj-openmenu ()
  (interactive)
  (ls-proj-genmenu (not current-prefix-arg)))

;;; ---------- 变量替换 / 表达式读取 ----------

(defun expand-dollar-string-with-alist (str &optional vars-alist)
  "扩展 $VAR，不扩展 ${VAR}。
优先级：1. vars-alist  2. defvar 全局 elisp 变量  3. 系统环境变量；找不到原样保留。
lex 模式下无法读取 let 局部变量。
vars-alist: ((\"proj-el-dir\" . \"/xxx\") ...)"
  (replace-regexp-in-string
   "\\$\\(\\([a-zA-Z0-9_-]+\\)\\)"
   (lambda (whole)
     (let* ((varname (match-string 2 whole))
            (found (and vars-alist (assoc varname vars-alist))))
       (cond
        (found (format "%s" (cdr found)))
        ((let ((sym (intern varname)))
           (and (boundp sym)
                (not (local-variable-p sym))
                (symbol-value sym))))
        ((getenv varname))
        (t whole))))
   str t t))

(defun expand-dollar-braces-string-eval-with-alist  (str &optional alist)
  "Replace every ${{EXPR}} in STR with the result of evaluating EXPR."
  (with-temp-buffer
    (insert str)
    (goto-char (point-min))
    (while (re-search-forward "\\${{" nil t)
      (let ((start (match-beginning 0)))
        (goto-char (match-end 0))
        (let ((end (search-forward "}}" nil t)))
          (unless end
            (error "Unterminated ${{ expression in %S" str))
          (let* ((expr (buffer-substring-no-properties (+ start 3) (- end 2)))
                 (val-str (let ((val (save-match-data (eval (read expr) alist))))
                            (if (stringp val) val (prin1-to-string val)))))
            (goto-char start)
            (delete-region start end)
            (insert val-str)
            (goto-char (+ start (length val-str)))))))
    (buffer-string)))

(defun read-all-from-string (str)
  "从字符串读取全部 elisp 表达式，返回 list。
处理多行、多个 sexp；任何读取错误立即停止。"
  (let ((pos 0)
        (result '())
        len form)
    (setq len (length str))
    (while (< pos len)
      (condition-case nil
          (setq form (read-from-string str pos))
        (error (setq form nil)))
      (if (not form)
          (setq pos len)
        (push (car form) result)
        (setq pos (cdr form))))
    (nreverse result)))

;;; ---------- 前言 elisp 抽取 / 执行 ----------

(defun proj--extract-preamble-blocks (content)
  "从 CONTENT 中抽取第一个 org heading 之前的所有
`#+begin_src elisp'/`emacs-lisp' 代码块。
返回 (CLEANED . BLOCKS)：
- CLEANED 是删除了这些代码块后的内容；
- BLOCKS 是这些代码块的源码字符串列表（自上而下）。"
  (with-temp-buffer
    (insert content)
    (let* ((case-fold-search t)
           (limit (save-excursion
                    (goto-char (point-min))
                    (if (re-search-forward "^\\*+ " nil t)
                        (match-beginning 0)
                      (point-max))))
           (ranges nil)
           (blocks nil))
      (goto-char (point-min))
      (while (re-search-forward
              "^[ \t]*#\\+begin_src[ \t]+\\(?:elisp\\|emacs-lisp\\)\\b[^\n]*\n"
              limit t)
        (let ((beg (match-beginning 0))
              (code-beg (match-end 0)))
          (if (re-search-forward "^[ \t]*#\\+end_src[^\n]*\n?" limit t)
              (let ((code-end (match-beginning 0))
                    (end (match-end 0)))
                (push (cons beg end) ranges)
                (push (buffer-substring-no-properties code-beg code-end)
                      blocks))
            ;; 未闭合：停止，保留原样
            (goto-char limit))))
      ;; ranges 是从下到上（push 的反向），按该顺序删除不会互相干扰
      (dolist (r ranges)
        (delete-region (car r) (cdr r)))
      (cons (buffer-string) (nreverse blocks)))))

(defun proj--read-and-eval-preamble (box)
  "若无 BOX 则直接返回 nil；否则把 (car BOX) 里的代码按顺序 eval。
BOX 是 (LIST) 形式的可变容器，可跨函数共享。"
  (when box
    (dolist (code (reverse (car box)))
      (condition-case err
          (dolist (form (read-all-from-string code))
            (eval form t))
        (error
         (message "[proj.el] preamble elisp eval error: %s" err))))))

;;; ---------- 命令分发 ----------
(defun alist-keys-to-symbol (alist)
  "把 ALIST 的字符串 key 全部转成符号，其余原样保留。"
  (mapcar (lambda (cell)
            (let ((k (car cell)))
              (cons (if (stringp k) (intern k) k)
                    (cdr cell))))
          alist))

(defun alist-keys-to-string (alist)
  "把 ALIST 的符号 key 全部转成字符串，其余原样保留。"
  (mapcar (lambda (cell)
            (let ((k (car cell)))
              (cons (if (symbolp k) (symbol-name k) k)
                    (cdr cell))))
          alist))

(defun mycompile (title cmd comment props)
  "菜单命令入口，按 comment 分支执行。"
  (interactive)
  (let* ((workdir-entry  (assoc 'workdir props))
         (workdir-path        (and workdir-entry (cdr workdir-entry)))
         (workdir  (when workdir-path
                     (if (file-directory-p workdir-path) workdir-path (file-name-directory workdir-path))))
         (userawcmd-entry (assoc 'rawcmd props))
         (userawcmd      (and userawcmd-entry
                              (not (= 0 (string-to-number (cdr userawcmd-entry))))))
         (path-entry  (assoc 'path props))
         (path-path        (and path-entry (cdr path-entry)))
         (ls-proj-root   proj-el-dir)
         (curdir         (or workdir ls-proj-root))
         (oldpath        (getenv "PATH"))
         (oldexecc       exec-path)
         (oldcmd         cmd) (alist)(alist1)(item))
    (message "[mycompile] title=%s, cmd=%s, comment=%s, workdir=%s"
             title cmd comment workdir)
    (unless comment (setq comment ""))
    (setq alist `((projdir . ,ls-proj-root)))
    (when curdir
      (setenv "WORKDIR" curdir)
      (setq alist (append alist `((workdir . ,curdir))))
      (setq props (assq-delete-all 'workdir props)))
    (when path-path
      (setenv "PATH" (concat path-path path-separator (getenv "PATH")))
      (dolist (item (reverse (split-string path-path path-separator)))
        (add-to-list 'exec-path item)))
    (when ls-proj-root (setenv "PROJDIR" ls-proj-root))
    (setq alist (append alist props))
    (setq alist1 (alist-keys-to-string alist))
    (proj-toggle-shell-bash t)
    (proj-toggle-shell-bash t t)
    (unless (or userawcmd (string= comment "eval"))
      (setq cmd (expand-dollar-braces-string-eval-with-alist (expand-dollar-string-with-alist cmd alist1) alist)))
    (unwind-protect
        (cond
         ((string= comment "eval")
          (let ((default-directory curdir))
            (dolist (e (read-all-from-string oldcmd))
              (eval e alist))))
         ((string= comment "xterm")
          (my-xterm cmd t curdir))
         ((string-prefix-p "term" comment)
          (let ((p (split-string comment ",")))
            (my-term cmd proj-edit-before-run curdir (nth 1 p) (nth 2 p))))
         ((string-prefix-p "pterm" comment)
          (let ((p (split-string comment ",")))
            (my-pterm cmd proj-edit-before-run curdir (nth 1 p) (nth 2 p) (nth 3 p))))
         ((string-prefix-p "shell" comment)
          (let ((p (split-string comment ",")))
            (my-shell cmd proj-edit-before-run curdir (nth 1 p) (nth 2 p))))
         ((string-prefix-p "pshell" comment)
          (let ((p (split-string comment ",")))
            (my-pshell cmd proj-edit-before-run curdir (nth 1 p) (nth 2 p) (nth 3 p))))
         ((string-prefix-p "eshell" comment)
          (let ((p (split-string comment ",")))
            (my-eshell cmd proj-edit-before-run curdir
                       (when (nth 1 p) (string-to-number (nth 1 p))))))
         ((string= comment "gdb")
          (my-gdb cmd curdir))
         ((string= comment "gud-gdb")
          (my-gud-gdb cmd proj-edit-before-run curdir))
         (t
	  (my-compile cmd proj-edit-before-run curdir t)
          ))
      (setenv "PATH" oldpath)
      (setq exec-path oldexecc))))

;;; ---------- 属性合并 / 继承 ----------

(defun proj-merge-props (parent-props child-props)
  "合并父子属性：child 覆盖 parent，返回新 alist。"
  (let ((merged (copy-alist parent-props)))
    (dolist (p child-props merged)
      (setq merged (assq-delete-all (car p) merged))
      (push p merged))))

(defun proj-find-parent-props (cur-level prop-stack)
  "从 prop-stack 找小于 cur-level 的最大 level 对应的 props，用于继承。"
  (let ((candidates (delq nil
                          (mapcar (lambda (e)
                                    (when (< (car e) cur-level) e))
                                  prop-stack))))
    (if candidates
        (cdar (sort candidates (lambda (a b) (> (car a) (car b)))))
      nil)))

;;; ---------- 菜单树简化 ----------

(defun proj-menu-simplify-leaf (node)
  "递归简化菜单节点。"
  (cond
   ((not (listp node)) node)
   ((and (= (length node) 2) (vectorp (nth 1 node)))
    (nth 1 node))
   ((> (length node) 1)
    (cons (car node)
          (mapcar #'proj-menu-simplify-leaf (cdr node))))
   (t node)))

(defun proj-menu-simplify-top (top-menus)
  "处理顶层菜单列表：顶层保持菜单结构，只简化其中的子节点。"
  (mapcar (lambda (top)
            (if (and (listp top) (cdr top))
                (cons (car top)
                      (mapcar #'proj-menu-simplify-leaf (cdr top)))
              top))
          top-menus))

;;; ---------- 默认菜单（.menu.org 无菜单项时使用） ----------

(defun proj--default-menu-tree ()
  "没有任何有效 .menu.org 菜单项时使用的 `myhelp' 帮助菜单。
公共项只在独立的 `projmenu' 顶层菜单里，这里不包含。"
  (list
   (list "myhelp"
         (vector "project menu install help"
                 (lambda ()
                   (interactive)
                   (find-file (expand-file-name "readme.txt"
                                                user-emacs-directory))))
         (vector "project menu usage help"
                 (lambda ()
                   (interactive)
                   (find-file (expand-file-name "proj-readme.org"
                                                user-emacs-directory))))
         (vector "then copy default menu" 'ls-proj-genmenu)
         (vector "or use default menu" 'ls-proj-defmenu))))

(defun proj--menu-tree-has-items-p (menu-tree)
  "MENU-TREE 中是否至少有一个带 items 的顶层菜单。
用于判别 .menu.org 是否真的定义了菜单项。"
  (let (found)
    (dolist (top menu-tree)
      (when (and (consp top) (cdr top))
        (setq found t)))
    found))

;;; ---------- #+INCLUDE 展开 ----------

(defun proj--include-target (arg dir)
  "解析 `#+INCLUDE:' 的参数 ARG，返回相对 DIR 的绝对文件名；无法解析返回 nil。
支持 `#+INCLUDE: a.org' 与 `#+INCLUDE: \"a.org\"'，忽略 :lines 等后缀参数。"
  (when (and arg (stringp arg))
    (let ((arg (string-trim arg)))
      (when (> (length arg) 0)
        (let ((file (if (string-match "\\`\"\\([^\"]*\\)\"" arg)
                        (match-string 1 arg)
                      (car (split-string arg "[ \t\n]+")))))
          (when (and file (not (string= file "")))
            (expand-file-name file dir)))))))

(defun proj--read-file-expanded (file &optional depth seen preamble-box)
  "读取 FILE 内容，并把 `#+INCLUDE: f' 行替换成 F 的内容（递归展开）。
包含路径相对 FILE 所在目录解析；DEPTH / SEEN 用于防止循环包含。
PREAMBLE-BOX 非 nil 时，是 (LIST) 形式的可变容器；每个文件第一个 org
heading 之前的 elisp 前言代码块会被 push 进 (car PREAMBLE-BOX)。
FILE 不存在时返回空串。"
  (let* ((depth (or depth 0))
         (file  (expand-file-name file))
         (seen  (or seen (list file))))
    (cond
     ((> depth 16)
      (message "[proj.el] include nesting too deep: %s" file)
      "")
     ((not (file-regular-p file))
      (message "[proj.el] include file not found: %s" file)
      "")
     (t
      (let* ((raw (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string)))
             (extracted (proj--extract-preamble-blocks raw))
             (content   (car extracted)))
        ;; 收集该文件的 elisp 前言
        (when preamble-box
          (dolist (b (cdr extracted))
            (setcar preamble-box (cons b (car preamble-box)))))
        ;; 逐行处理 INCLUDE
        (let* ((dir   (file-name-directory file))
               (lines (split-string content "\n"))
               (out nil)
               (case-fold-search t))
          (dolist (line lines)
            (if (string-match "\\`[ \t]*#\\+INCLUDE:[ \t]*\\(.*\\)\\'" line)
                (let* ((target (proj--include-target (match-string 1 line) dir))
                       (path   (and target (expand-file-name target))))
                  (cond
                   ((null path) (push line out))
                   ((member path seen)
                    (message "[proj.el] circular include skipped: %s" path)
                    (push line out))
                   (t
                    (push (proj--read-file-expanded path (1+ depth)
                                                     (cons path seen)
                                                     preamble-box)
                          out))))
              (push line out)))
          (mapconcat #'identity (nreverse out) "\n")))))))

;;; ---------- .menu.org 解析 ----------

(defun proj-parse-menu-org (org-file)
  "解析 ORG-FILE，返回 easy-menu 可用的菜单树。
ORG-FILE 中的 `#+INCLUDE: f' 会先把 f 的内容就地展开再解析；
每个文件第一个 heading 之前的 elisp 前言代码块会先被执行，
并从内容中删除，避免被解析成菜单项 cmd。"
  (require 'org)
  (setq current-menu-org-file org-file)
  (let ((root-stack nil)
        (prop-stack nil)
        (result nil)
        (preamble-box (list nil)))
    (with-temp-buffer
      (delay-mode-hooks (org-mode))
      (if (file-exists-p org-file)
          (insert (proj--read-file-expanded org-file nil nil preamble-box))
        (insert "* build\n"))

      ;; 先执行所有文件的前言 elisp（按文件先后顺序）
      (proj--read-and-eval-preamble preamble-box)

      (goto-char (point-min))
      (while (re-search-forward org-heading-regexp nil t)
        (let* ((level (org-current-level))
               (raw-title (org-get-heading t t t t))
               (title-and-comment (split-string raw-title " *# *"))
               (title (car title-and-comment))
               (comment (if (> (length title-and-comment) 1)
                            (mapconcat #'identity (cdr title-and-comment) "#")
                          nil))
               (local-props
                (save-excursion
                  (org-end-of-meta-data t)
                  (let ((plist nil))
                    (while (and (not (eobp))
                                (not (looking-at "^\\*")))
                      (when (looking-at "^#\\+\\([^:]+\\):[ \t]*\\(.*\\)")
                        (let ((key (intern (downcase (match-string 1))))
                              (val (match-string 2)))
                          (setq plist (assq-delete-all key plist))
                          (push (cons key (expand-dollar-string-with-alist val)) plist)))
                      (forward-line 1))
                    (nreverse plist))))
               (cmd (save-excursion
                      (org-end-of-meta-data t)
                      ;; 起始位置：跳过空行 / #+关键字 / 以 "# " 开头的 org
                      ;; 注释行；被 #+INCLUDE 展开进文件头的说明性注释也
                      ;; 属于这一类，不能当成 cmd 内容。
                      (while (and (not (eobp))
                                  (or (looking-at "[ \t]*$")
                                      (looking-at "^#\\+")
                                      (looking-at "^#[ \t]")))
                        (forward-line 1))
                      (if (or (eobp) (looking-at "^\\*"))
                          nil
                        ;; 逐行收集，跳过 org 注释行；这样 include 文件开头
                        ;; 的注释块不会被拼进上一个菜单项的 cmd，也不会
                        ;; 让 "${{EXPR}}" 求值读到 "# ... ${{var}} ..."
                        ;; 之类的说明文字而报 "var is void"。
                        (let ((lines '()))
                          (while (and (not (eobp))
                                      (not (looking-at "^\\*")))
                            (unless (looking-at "^#[ \t]")
                              (push (buffer-substring-no-properties
                                     (line-beginning-position)
                                     (line-end-position))
                                    lines))
                            (forward-line 1))
                          (let ((s (string-trim-right
                                    (mapconcat #'identity
                                               (nreverse lines) "\n"))))
                            ;; 全为注释 / 空白时返回 nil，避免生成空 cmd 菜单项
                            (if (string= s "") nil s))))))
               (parent-props (proj-find-parent-props level prop-stack))
               (props (proj-merge-props parent-props local-props))
               (node (list title)))
          (while (and root-stack (> (caar root-stack) (1- level)))
            (pop root-stack))
          (while (and prop-stack (> (caar prop-stack) (1- level)))
            (pop prop-stack))
          (when cmd
            (setq node
                  (list title
                        (vector title
                                (lambda ()
                                  (interactive)
                                  (mycompile title cmd comment props))))))
          (if root-stack
              (nconc (cdar root-stack) (list node))
            (push node result))
          (push (cons level node) root-stack)
          (push (cons level props) prop-stack))))
    (proj-menu-simplify-top (nreverse result))))

;;; ---------- 项目文件子菜单 ----------

(defun proj--project-file-buffers ()
  "返回当前项目文件根目录（`proj-project-roots'，未设置时退回
\(`proj-el-dir'）下所有已打开文件的 buffer。"
  (let ((dirs (or proj-project-roots
                  (list (expand-file-name
                         (or proj-el-dir default-directory)))))
        (bufs nil))
    (dolist (buf (buffer-list))
      (let ((file (buffer-file-name buf)))
        (when (and file (proj--file-in-dirs-p file dirs))
          (push buf bufs))))
    (nreverse bufs)))

(defun proj--open-all-project-files (&optional bufs)
  "对所有项目文件 buffer 依次执行 `switch-to-buffer'。
跳过 TAGS / tags 文件。"
  (interactive)
  (unless bufs (setq bufs (proj--project-file-buffers)))
  (let ((opened 0))
    (dolist (buf bufs)
      (let ((name (file-name-nondirectory (buffer-file-name buf))))
        (unless (member name '("TAGS" "tags"))
          (switch-to-buffer buf)
          (setq opened (1+ opened))
	  (when (= opened 1)
	    (if (fboundp 'tab-line-close-other-tabs)
		(tab-line-close-other-tabs)
		(split-window-below) (other-window 1) (delete-other-windows))
	    )
	  )))
    (unless (> opened 0)
      (message "[proj.el] no project buffers (except TAGS/tags)"))))

(defun proj--close-all-other-files ()
  "关闭所有不在当前项目文件根目录下的 buffer。关闭前需确认。"
  (interactive)
  (let ((keep (proj--project-file-buffers))
        (to-kill nil))
    (dolist (buf (buffer-list))
      (let ((name (buffer-name buf)))
        (unless (or (memq buf keep)
                    (string-prefix-p " " name)
                    (string-prefix-p "*" name))
          (push buf to-kill))))
    (setq to-kill (nreverse to-kill))
    (cond
     ((null to-kill)
      (message "[proj.el] no non-project buffer(s) to close"))
     ((yes-or-no-p (format "Kill %d non-project buffer(s)? " (length to-kill)))
      (let ((killed 0))
        (dolist (buf to-kill)
          (condition-case err
              (progn (kill-buffer buf)
                     (setq killed (1+ killed)))
            (error (message "[proj.el] kill-buffer %s: %s" (buffer-name buf) err))))
        (message "[proj.el] killed %d non-project buffer(s)" killed))))))

(defun proj--project-file-items (&rest _)
  "构造当前项目文件根目录下已打开 buffer 文件的菜单项列表。"
  (let ((bufs (proj--project-file-buffers)))
    (if bufs
        (append
         (list ["Open all files" proj--open-all-project-files])
         '("--")
         (mapcar (lambda (buf)
                   (vector (file-name-nondirectory (buffer-file-name buf))
                           (lambda ()
                             (interactive)
                             (switch-to-buffer buf))))
                 bufs)
         '("--")
         (list ["Close all other files" proj--close-all-other-files]))
      (list ["(no project buffers)" nil t]))))

;;; ---------- Projects 子菜单（按 .menu.org 归组） ----------

(defun proj--find-project-root (file)
  "从 FILE 所在目录向上找到最近的包含 .menu.org 的目录，返回该目录（带尾斜杠）。
找不到返回 nil。"
  (let ((dir (file-name-directory (expand-file-name file)))
        (root nil))
    (while (and dir (not root))
      (if (file-exists-p (expand-file-name ".menu.org" dir))
          (setq root dir)
        (let ((parent (file-name-directory (directory-file-name dir))))
          (setq dir (unless (equal parent dir) parent)))))
    root))

(defun proj--project-buffer-groups ()
  "返回 ((工程根目录 . (buffer ...)) ...)。
归组依据仍是 .menu.org 所在目录（显示方法不变）。"
  (let ((table (make-hash-table :test 'equal))
        (order nil))
    (dolist (buf (buffer-list))
      (let ((file (buffer-file-name buf)))
        (when file
          (let ((root (proj--find-project-root file)))
            (unless (gethash root table)
              (push root order))
            (puthash root (cons buf (gethash root table)) table)))))
    (let* ((roots (nreverse order))
           (has-noproject (and (memq nil roots) t)))
      (setq roots (append (delq nil roots)
                          (when has-noproject (list nil))))
      (mapcar (lambda (root)
                (cons root (nreverse (gethash root table))))
              roots))))

(defun proj--close-project-files (root)
  "关闭 ROOT 目录下所有已打开的 buffer，关闭前需确认。"
  (let* ((dir  (expand-file-name root))
         (bufs nil))
    (dolist (buf (buffer-list))
      (let ((file (buffer-file-name buf)))
        (when (and file (file-in-directory-p file dir))
          (push buf bufs))))
    (setq bufs (nreverse bufs))
    (cond
     ((null bufs)
      (message "[proj.el] no buffers under %s" root))
     ((yes-or-no-p (format "Kill %d buffer(s) under %s? "
                           (length bufs) root))
      (let ((killed 0))
        (dolist (buf bufs)
          (condition-case err
              (progn (kill-buffer buf)
                     (setq killed (1+ killed)))
            (error (message "[proj.el] kill-buffer %s: %s" (buffer-name buf) err))))
        (message "[proj.el] killed %d buffer(s) under %s" killed root))))))

(defun proj--close-buffers (bufs)
  "关闭 BUFS 中所有 buffer，关闭前需确认。"
  (cond
   ((null bufs)
    (message "[proj.el] no buffers to close"))
   ((yes-or-no-p (format "Kill %d buffer(s)? " (length bufs)))
    (let ((killed 0))
      (dolist (buf bufs)
        (condition-case err
            (progn (kill-buffer buf)
                   (setq killed (1+ killed)))
          (error (message "[proj.el] kill-buffer %s: %s" (buffer-name buf) err))))
      (message "[proj.el] killed %d buffer(s)" killed)))))

(defun proj--project-menu-items (&rest _)
  "Projects 子菜单项：每个工程（按 .menu.org 归组）一个子菜单。
显示方法保持不变；点击 `open project files' 时会用当前
`proj-project-roots' 语义来打开/关闭。"
  (let* ((groups (proj--project-buffer-groups))
         (counts (make-hash-table :test 'equal)))
    (dolist (cell groups)
      (when (car cell)
        (let ((name (file-name-nondirectory (directory-file-name (car cell)))))
          (puthash name (1+ (or (gethash name counts) 0)) counts))))
    (if groups
        (mapcar
         (lambda (cell)
           (let* ((root  (car cell))
                  (bufs  (cdr cell))
                  (name  (if root
                             (file-name-nondirectory (directory-file-name root))
                           "noproject"))
                  (label (if (and root (> (gethash name counts) 1))
                             (abbreviate-file-name (directory-file-name root))
                           name)))
             (cons label
                   (append
                    (list (vector "open project files"
                                  (lambda ()
                                    (interactive)
                                    (proj--open-all-project-files bufs))))
                    '("--")
                    (mapcar (lambda (buf)
                              (vector (file-name-nondirectory (buffer-file-name buf))
                                      (lambda ()
                                        (interactive)
                                        (switch-to-buffer buf))))
                            bufs)
                    '("--")
                    (list
                     (vector "close this project files"
                             (if root
                                 (lambda ()
                                   (interactive)
                                   (proj--close-project-files root))
                               (lambda ()
                                 (interactive)
                                 (proj--close-buffers bufs))))
                     (vector "switch to this project"
                             (lambda ()
                               (interactive)
                               (when root
                                 (proj--switch-to-project root)))
                             :active (and root t)))))))
         groups)
      (list ["(no project buffers)" nil t]))))

;;; ---------- Windows shell 切换 ----------

(defun proj-shell-is-bash-p (&optional exp)
  (and (stringp (if exp explicit-shell-file-name shell-file-name))
       (string-match-p "bash" (file-name-nondirectory (if exp explicit-shell-file-name shell-file-name)))))

(defun proj-toggle-shell-bash (&optional reset exp)
  (interactive)
  (if (if reset (not (proj-shell-is-bash-p exp)) (proj-shell-is-bash-p exp))
      (if exp
          (setq explicit-shell-file-name (or (executable-find "cmdproxy.exe")
                                             "cmdproxy.exe"))
        (setq shell-file-name (or (executable-find "cmdproxy.exe")
                                  "cmdproxy.exe"))
        (setq shell-command-switch "/c"))
    (if exp (setq explicit-shell-file-name (or (executable-find "bash.exe")
                                               (executable-find "bash")
                                               "bash.exe"))
      (setq shell-file-name (or (executable-find "bash.exe")
                                (executable-find "bash")
                                "bash.exe")))
    (setq shell-command-switch "-c"))
  (message "shell-file-name = %s   shell-command-switch = %s"
           shell-file-name shell-command-switch))

(defun proj-explict-shell-is-bash-p ()
  (proj-shell-is-bash-p t))

(defun proj-toggle-explict-shell-bash (&optional reset)
  (interactive)
  (proj-toggle-shell-bash reset t))

(defun proj-toggle-compilation-is-in-newwin ()
  (interactive)
  (not (eq compilation-buffer-name-function  'compilation--default-buffer-name))
    )

(defun proj-toggle-compilation-in-newwin (&optional reset)
  (interactive)
  (if (or reset (eq compilation-buffer-name-function  'compilation--default-buffer-name))
      (setq compilation-buffer-name-function
	    (lambda (mode)
	      (generate-new-buffer-name "*compilation*")))
    (setq compilation-buffer-name-function 'compilation--default-buffer-name)
    ))
(defun proj-edit-before-run (&optional reset)
  (interactive)
  (if proj-edit-before-run
      (setq proj-edit-before-run nil)
    (setq proj-edit-before-run t)
    )
  (customize-save-variable 'proj-edit-before-run proj-edit-before-run)
  )

;;; ---------- 公共菜单项（独立 `projmenu' 顶层菜单 + context menu） ----------

(defun proj--modes-submenu ()
  "Modes 子菜单。"
  '("Modes"
    ["evil Mode"      evil-mode         :style toggle :selected evil-mode]
    ["CUA Mode"       cua-mode          :style toggle :selected cua-mode]
    ["Debug on Error" toggle-debug-on-error
     :style toggle :selected debug-on-error]
    ["compile in newwin" proj-toggle-compilation-in-newwin
     :style toggle
     :selected (proj-toggle-compilation-is-in-newwin)]
    ["edit before run" proj-edit-before-run
     :style toggle
     :selected proj-edit-before-run]
    ["bash" proj-toggle-shell-bash
     :style toggle
     :selected (proj-shell-is-bash-p)
     :active (eq system-type 'windows-nt)]
    ["bash all" proj-toggle-explict-shell-bash
     :style toggle
     :selected (proj-explict-shell-is-bash-p)
     :active (eq system-type 'windows-nt)]))

(defun proj--history-submenu ()
  "Project history 子菜单。"
  (cons "Project history"
        (append
         (mapcar (lambda (dir)
                   (vector (abbreviate-file-name dir)
                           (lambda ()
                             (interactive)
                             (proj--switch-to-project dir))))
                 proj-history)
         (when proj-history '("--"))
         (list ["Clear history" proj-history-clear]))))

(defun proj--common-menu-items ()
  "独立的 `projmenu' 顶层菜单项（无条件显示）。
不再追加到 .menu.org 定义的各顶层菜单末尾。"
  (append
   '("--")
   (list (proj--modes-submenu))
   '("--")
   '(["Reload Menu" proj-rebuild-menu-from-org])
   '(["open menu" ls-proj-openmenu])
   '(["generate/open menu" ls-proj-genmenu])
   '(["use default menu" ls-proj-defmenu])
   '("--")
   (list (vector (concat "Project: " (or proj-el-dir "(none)")) nil))
   '(["Change project"    ls-proj-set])
   '(["open project file" ls-proj-openfile])
   (list (cons "Project files"
               (list :filter #'proj--project-file-items)))
   (list (cons "Projects"
               (list :filter #'proj--project-menu-items)))
   (list (proj--history-submenu))))

;;; ---------- 菜单重建 ----------

(defun proj--install-menu (title items)
  "创建顶层菜单 TITLE（ITEMS），绑定到 menu-bar，并缓存源顺序 items。
返回菜单符号。"
  (let* ((sym (intern (concat "menu-bar-" title))))
    (puthash title items proj--menu-item-lists)
    (define-key-after global-map
      (vector 'menu-bar sym)
      (cons title (easy-menu-create-menu title items))
      'tools)
    sym))

(defun proj-rebuild-menu-from-org (&optional menu-org-file)
  "读取 .menu.org，重建菜单。
`projmenu' 顶层菜单无条件存在，承载全部公共项；
.menu.org 里定义的每个顶层菜单独立存在、互不混入公共项；
.menu.org 没有任何菜单项（或缺失）时回退到 `myhelp'。
重建时会读取 .menu.org 第一行 `#+proj:'（可多个目录）刷新
`proj-project-roots'。"
  (interactive)
  (require 'easymenu)
  (unless menu-bar-mode (menu-bar-mode 1))
  (when proj-el-dir
    ;; 用 .menu.org 第一行的 `#+proj:' 刷新项目文件根目录列表
    (setq proj-project-roots (proj--proj-dir-attr proj-el-dir))
    ;; 重建前清理必要缓存
    (clrhash proj--menu-item-lists)
    ;; >>> FIX: 必须「先恢复、后快照保存」。
    ;; 以前的顺序是直接 remember，启动时 buffer 列表为空，
    ;; 会把磁盘上保存的文件列表覆盖成只有目录本身。
    (proj--restore-once proj-el-dir)
    (proj--remember-project-files proj-el-dir))
  (proj-history-add proj-el-dir)
  (dolist (sym proj-menu--symbols)
    (define-key global-map (vector 'menu-bar sym) nil))
  (setq proj-menu--symbols nil)
  (clrhash proj--menu-item-lists)
  ;; 1) 公共菜单：无条件
  (push (proj--install-menu "projmenu" (proj--common-menu-items))
        proj-menu--symbols)
  ;; 2) .menu.org 的顶层菜单；一个菜单项都没有时回退到 myhelp
  (let* ((org-path (or menu-org-file
                       (expand-file-name ".menu.org" proj-el-dir)))
         (menu-tree (proj-parse-menu-org org-path)))
    (unless (proj--menu-tree-has-items-p menu-tree)
      (setq menu-tree (proj--default-menu-tree)))
    (dolist (top-node (nreverse menu-tree))
      (let ((title (car top-node))
            (items (cdr top-node)))
        (when items
          (push (proj--install-menu title items)
                proj-menu--symbols)))))
  (garbage-collect))

;;; ---------- 以命令方式调用菜单项 ----------

(defun proj--escape-title (title)
  "把 TITLE 中的 `/` 转义为 `\\/'，用于构成可反解析的路径字符串。"
  (if (stringp title)
      (replace-regexp-in-string "/" "\\/" title t t)
    title))

(defun proj--split-path-string (str)
  "按未转义的 `/` 切分 STR，并把 `\\/' 还原为 `/`。"
  (let ((parts nil)
        (cur "")
        (i 0)
        (n (length str)))
    (while (< i n)
      (let ((c (aref str i)))
        (cond
         ((and (eq c ?\\) (< (1+ i) n) (eq (aref str (1+ i)) ?/))
          (setq cur (concat cur "/"))
          (setq i (+ i 2)))
         ((eq c ?/)
          (push cur parts)
          (setq cur "")
          (setq i (1+ i)))
         (t
          (setq cur (concat cur (char-to-string c)))
          (setq i (1+ i))))))
    (push cur parts)
    (nreverse parts)))

(defun proj--lookup-submenu (menu-title)
  "返回顶层菜单 MENU-TITLE 对应的菜单 keymap。"
  (let* ((sym (intern (concat "menu-bar-" menu-title)))
         (val (lookup-key global-map (vector 'menu-bar sym))))
    (cond
     ((keymapp val) val)
     ((and (consp val) (keymapp (cdr val))) (cdr val))
     (t nil))))

(defun proj--entry-name (entry)
  "返回菜单 ENTRY 的标题字符串；分隔符等不可命名项返回 nil。"
  (cond
   ((and (consp entry) (eq (car entry) 'menu-item))
    (let ((n (nth 1 entry))) (and (stringp n) n)))
   ((vectorp entry)
    (let ((n (aref entry 0))) (and (stringp n) n)))
   ((and (consp entry) (stringp (car entry)))
    (car entry))
   (t nil)))

(defun proj--entry-command (entry)
  "返回菜单 ENTRY 对应的命令；子菜单 / 分隔符返回 nil 或 keymap。"
  (cond
   ((and (consp entry) (eq (car entry) 'menu-item))
    (nth 2 entry))
   ((vectorp entry)
    (and (> (length entry) 1) (aref entry 1)))
   ((and (consp entry) (stringp (car entry)))
    (let ((def (cdr entry)))
      (unless (or (keymapp def)
                  (and (consp def) (eq (car def) :filter)))
        def)))
   (t nil)))

(defun proj--entry-submenu (entry)
  "若 ENTRY 是子菜单，返回其内容（keymap 或 items 列表）；否则 nil。
支持 :filter 动态子菜单：filter 是 1 参数的 wrapper（由 easy-menu 生成），
必须传入菜单名（函数体会忽略它），否则会被 `ignore-errors' 吞掉而返回 nil。"
  (cond
   ((and (consp entry) (eq (car entry) 'menu-item))
    (let* ((name   (or (proj--entry-name entry) "submenu"))
           (def    (nth 2 entry))
           (filter (plist-get (nthcdr 3 entry) :filter)))
      (cond
       (filter
        (let ((result (ignore-errors (funcall filter name))))
          (cond
           ((null result) nil)
           ((keymapp result) result)
           (t (or (ignore-errors (easy-menu-create-menu name result))
                  result)))))
       ((keymapp def) def)
       (t nil))))
   ((and (consp entry) (stringp (car entry)))
    (let* ((name (car entry))
           (def  (cdr entry)))
      (cond
       ((keymapp def) def)
       ((and (consp def) (eq (car def) :filter))
        (let ((result (ignore-errors (funcall (cadr def) name))))
          (cond
           ((null result) nil)
           ((keymapp result) result)
           (t (or (ignore-errors (easy-menu-create-menu name result))
                  result)))))
       ((listp def) def)
       (t keymapp))))
   (t nil)))

(defun proj--map-menu-entries (menu fn)
  "遍历 MENU（keymap 或 items 列表），对每个命名条目调用 FN，参数为 (TITLE . ENTRY)。"
  (cond
   ((keymapp menu)
    (map-keymap
     (lambda (_key binding)
       (let ((title (proj--entry-name binding)))
         (when (and title (not (string= title "--")))
           (funcall fn title binding))))
     menu))
   ((listp menu)
    (dolist (item menu)
      (let ((title (proj--entry-name item)))
        (when (and title (not (string= title "--")))
          (funcall fn title item)))))
   (t nil)))

(defun proj--find-entry-in-menu (menu titles)
  "在 MENU 中沿 TITLES 查找，返回最终 ENTRY；任一级缺失返回 nil。"
  (let (entry)
    (catch 'fail
      (while titles
        (let ((title (car titles)))
          (setq entry nil)
          (proj--map-menu-entries
           menu
           (lambda (t e) (when (equal t title) (setq entry e))))
          (unless entry (throw 'fail nil))
          (setq titles (cdr titles))
          (when titles
            (setq menu (proj--entry-submenu entry))
            (unless menu (throw 'fail nil))))))
    entry))

(defun proj--titles-exist-p (map titles)
  "判断 TITLES 这条标题链在 MAP 中是否完整存在。"
  (and (proj--find-entry-in-menu map titles) t))

(defun proj--find-menu-item-command (menu-title item-titles)
  "在顶层菜单 MENU-TITLE 中按标题路径 ITEM-TITLES 递归查找菜单项。"
  (let* ((titles (cond ((null item-titles) nil)
                       ((listp item-titles) item-titles)
                       (t (list item-titles))))
         (menu (proj--lookup-submenu menu-title))
         (entry (and menu titles (proj--find-entry-in-menu menu titles))))
    (when entry
      (or (proj--entry-command entry)
          (let ((sub (proj--entry-submenu entry)))
            (cond
             ((keymapp sub) sub)
             (sub (ignore-errors
                    (easy-menu-create-menu
                     (or (proj--entry-name entry) "submenu") sub)))
             (t nil)))))))

(defun proj--backtrack-resolve (map str)
  "用「最长前缀优先 + 回溯」在 MAP 下把 STR 解析成标题列表。"
  (if (string= str "")
      nil
    (if (proj--find-entry-in-menu map (list str))
        (list str)
      (let ((prefixes nil)
            (pos 0))
        (while (string-match "/" str pos)
          (push (substring str 0 (match-beginning 0)) prefixes)
          (setq pos (1+ (match-beginning 0))))
        (catch 'found
          (dolist (p prefixes)
            (let ((entry (proj--find-entry-in-menu map (list p))))
              (when entry
                (let* ((submap (proj--entry-submenu entry))
                       (rest   (substring str (1+ (length p))))
                       (sub    (and submap
                                    (proj--backtrack-resolve submap rest))))
                  (when sub
                    (throw 'found (cons p sub)))))))
          nil)))))

(defun proj--resolve-path-in-map (map str)
  "把 STR 解析为 MAP 下的标题列表；失败返回 nil。"
  (let ((parts (proj--split-path-string str)))
    (or (and (proj--titles-exist-p map parts) parts)
        (proj--backtrack-resolve map str))))

(defun proj--top-menu-titles ()
  "返回本包当前创建的所有顶层菜单标题列表。"
  (let (titles)
    (dolist (s proj-menu--symbols (nreverse titles))
      (let ((name (symbol-name s)))
        (when (string-prefix-p "menu-bar-" name)
          (push (substring name 9) titles))))))

(defun proj--resolve-full-path (menuname)
  "把完整菜单路径 MENUNAME 解析成 (TOP . TITLES)。"
  (let* ((tops (proj--top-menu-titles))
         (tops (sort (copy-sequence tops)
                     (lambda (a b) (> (length a) (length b))))))
    (catch 'found
      (dolist (top tops)
        (let* ((etop (proj--escape-title top))
               (elen (length etop)))
          (when (and (> (length menuname) elen)
                     (string= (substring menuname 0 elen) etop)
                     (eq (aref menuname elen) ?/))
            (let* ((rest   (substring menuname (1+ elen)))
                   (titles (proj--resolve-path-in-map
                            (proj--lookup-submenu top) rest)))
              (when titles
                (throw 'found (cons top titles)))))))
      nil)))

(defun proj--collect-menu-leaf-paths (menu &optional prefix)
  "递归收集 MENU 下所有叶子菜单项的路径，用 \"/\" 连接。
支持 keymap / items 列表；`:filter' 动态子菜单将被现场求值后展开。
遍历顺序 = items 顺序 = 源顺序，保证 .menu.org 定义的菜单项在前，
Modes / Project files / Projects 等附加项在后。"
  (let (paths)
    (proj--map-menu-entries
     menu
     (lambda (title entry)
       (let* ((etitle  (proj--escape-title title))
              (newpath (if prefix (concat prefix "/" etitle) etitle))
              (sub     (proj--entry-submenu entry)))
         (setq paths
               (nconc paths
                      (if (and sub (or (keymapp sub) (listp sub)))
                          (let ((desc (proj--collect-menu-leaf-paths sub newpath)))
                            (or desc (list newpath)))
                        (list newpath)))))))
    paths))

(defvar my-proj-call--last nil
  "上次成功调用的菜单路径。")

(defun proj-call-menu-item (menu-title item-title)
  "执行菜单栏 MENU-TITLE 下路径为 ITEM-TITLE 的菜单项。"
  (interactive
   (let* ((top    (completing-read "Menu: " (proj--top-menu-titles)))
          (items  (gethash top proj--menu-item-lists))
          (paths  (if items
                      (proj--collect-menu-leaf-paths items)
                    (let ((map (proj--lookup-submenu top)))
                      (and map (proj--collect-menu-leaf-paths map)))))
          (item   (if paths
                      (completing-read "Item path: " paths nil t)
                    (read-string "Item path: "))))
     (list top item)))
  (let* ((titles
          (cond
           ((null item-title) nil)
           ((listp item-title) item-title)
           (t (proj--resolve-path-in-map
               (proj--lookup-submenu menu-title)
               item-title))))
         (cmd (and titles
                   (proj--find-menu-item-command menu-title titles))))
    (cond
     ((null cmd)
      (user-error "menu item %S / %S not found" menu-title item-title))
     ((commandp cmd)
      (when (and menu-title titles)
        (setq my-proj-call--last
              (concat (proj--escape-title menu-title) "/"
                      (mapconcat #'proj--escape-title titles "/"))))
      (call-interactively cmd))
     ((keymapp cmd)
      (user-error "%S / %S is a submenu, not a command; specify a fuller path"
                  menu-title item-title))
     (t
      (user-error "%S / %S is not a callable command" menu-title item-title)))))

(evil-define-command my-proj-switch (newmenu)
  "交互式选择项目根目录并重建菜单。"
  (interactive "<f>")
  (unless newmenu
    (unless proj-el-dir (setq proj-el-dir default-directory))
    (let* ((default (expand-file-name ".menu.org" proj-el-dir))
           (cands
            (delete-dups
             (cons default
                   (mapcar (lambda (dir)
                             (expand-file-name ".menu.org" dir))
                           proj-history)))))
      (setq newmenu (completing-read "proj: " cands nil t nil nil default))
      (setq newmenu (read-file-name "proj: " (file-name-directory newmenu) newmenu t newmenu))))
  (let ((path (expand-file-name newmenu)))
    (when (file-directory-p path)
      (setq path (expand-file-name ".menu.org" path)))
    (proj--switch-to-project (file-name-directory path))))

(evil-define-command my-proj-call (menuname)
  "按路径执行菜单项，支持任意深度，标题中自带 `/` 可用 `\\/' 转义。"
  (interactive "<a>")
  (when (and current-prefix-arg my-proj-call--last)
    (setq menuname my-proj-call--last))
  (if menuname
      (let ((resolved (proj--resolve-full-path menuname)))
        (if resolved
            (proj-call-menu-item (car resolved) (cdr resolved))
          (user-error "menu path not found: %S" menuname)))
    (call-interactively 'proj-call-menu-item)))

;;; ---------- context menu 集成 ----------

(defun proj-context-menu (menu _click)
  "把菜单栏上的每个顶层菜单（含恒存在的 `projmenu'）加入上下文菜单 MENU。"
  (when (bound-and-true-p context-menu-mode)
    (if proj-menu--symbols
        (dolist (sym proj-menu--symbols)
          (let* ((name  (symbol-name sym))
                 (title (and (string-prefix-p "menu-bar-" name)
                             (substring name 9))))
            (when title
              (let* ((items (or (gethash title proj--menu-item-lists)
                                (list ["(empty)" nil t])))
                     (csym  (intern (concat "proj-ctx-" name)))
                     (sub   (ignore-errors
                              (easy-menu-create-menu title items))))
                (when (keymapp sub)
                  (define-key-after menu (vector csym)
                    (cons title sub) t))))))
      ;; 没有任何顶层菜单时，仍给出公共项，避免右键为空
      (let ((sub (ignore-errors
                   (easy-menu-create-menu "projmenu"
                                          (proj--common-menu-items)))))
        (when (keymapp sub)
          (define-key-after menu (vector 'projmenu)
            (cons "projmenu" sub) t)))))
  menu)

(when (boundp 'context-menu-functions)
  (add-to-list 'context-menu-functions #'proj-context-menu))

;;; ---------- 初始化 ----------

;; 不再在启动时缓存整个状态文件；写盘前实时读磁盘，只更新当前 project。
(add-hook 'kill-emacs-hook #'proj--on-kill-emacs)
(dolist (key '("C-z" "C-x j"))
  (general-define-key :prefix key
		      "p c" #'my-proj-call
		      "p s" #'my-proj-switch
		      "p S" #'ls-proj-set
		      "p o" #'ls-proj-openmenu
		      "p m" #'ls-proj-genmenu
		      "p O" #'proj--open-all-project-files
		      "p r" #'proj-rebuild-menu-from-org
		      "p R" #'ls-proj-defmenu
		      "p C" #'proj--close-all-other-files
		      "p f" #'ls-proj-openfile
		      "p b" #'(lambda ()(interactive) (my-proj-call my-proj-call--last))
		      ))

(provide 'proj)
;;; proj.el ends here

(proj-rebuild-menu-from-org)
