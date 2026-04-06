;;; magpt.el --- MaGPT: Git/Magit AI assistant via gptel  -*- lexical-binding: t; -*-

;; Author: Peter <11111000000@email.com>
;; URL: https://github.com/11111000000/magpt
;; Version: 1.7.5
;; Package-Requires: ((emacs "28.1") (gptel "0.9"))
;; Keywords: tools, vc, git, ai

;;; Commentary:
;;
;; MaGPT (magpt.el) is an Emacs package that augments your Git/Magit workflow
;; with AI-powered assistance via gptel. It started as an AI commit message
;; generator and is evolving towards a safe, task-oriented assistant that can:
;; - observe repository state and explain it,
;; - suggest next actions and commit structure,
;; - assist with messages, summaries, and release notes,
;; - provide reversible, preview-first help for complex flows (e.g., conflicts).
;;
;; Design principles:
;; - Provider-agnostic: inherit configuration from gptel; no hardcoding of models.
;; - Safety first: explicit confirmation before sending data; minimal context; masking-ready.
;; - Reversibility: never mutate without preview and confirmation; no hidden Git side-effects.
;; - Clear UX: async and non-blocking; overlays show progress; errors clean up gracefully.
;; - Extensible core: “Task” registry (context → prompt → request → render/apply) for future features.
;;
;; This file is organized into well-delimited sections to support future splitting
;; into multiple modules (core, commit, tasks, ui, etc.) without changing behavior.
;; All public entry points and user-facing behavior remain backward-compatible.

;;; Code:

;; Ensure local requires work when loading this file directly via load-file.
(eval-and-compile
  (let ((dir (file-name-directory (or load-file-name buffer-file-name))))
    (when (and dir (file-directory-p dir))
      (add-to-list 'load-path dir))))

;;;; Section: Dependencies and forward declarations
;;
;; We keep core deps lightweight. Magit/transient are optional. gptel is required for requests.

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'vc)
(require 'project)
(require 'gptel)

(require 'magit nil t)     ;; Optional; used when available
(require 'transient nil t) ;; Optional; used when available
(require 'magpt-log nil t)
(require 'magpt-ui-preview nil t)
(require 'magpt-magit-overview nil t)
(require 'magpt-history nil t) ;; ensure history API is accessible
(require 'magpt-tasks-core nil t)
(require 'magpt-tasks-assist nil t)
(require 'magpt-tasks-recommend nil t)
(require 'magpt-tasks-resolve nil t)
(require 'magpt-commit nil t)
(require 'magpt-transient nil t)
(require 'magpt-gpt nil t)
(require 'magpt-git nil t)

;; Ensure the logging toggle exists early so submodules that are loaded
;; before the full customization block do not see an unbound variable.
;; The long-form defcustom remains later to support customization UI;
;; this defvar merely ensures the variable is bound early (default: t).
(defvar magpt-log-enabled t
  "Non-nil enables diagnostic logging for magpt (early declaration).")

(declare-function magit-toplevel "ext:magit")
(declare-function magit-commit-create "ext:magit")
(declare-function transient-quit-all "ext:transient")
(declare-function magpt--recent-git-output-get "magpt-git" (dir))
(declare-function magpt--git-apply-temp "magpt-git" (dir patch &rest args))
(declare-function magpt--git-apply-check-temp "magpt-git" (dir patch &rest args))
;; `transient--prefix' is declared/owned by the Transient package at runtime.
;; DO NOT bind it at runtime in this feature: doing so registers the variable
;; as belonging to this feature and `unload-feature' may unbind it later,
;; causing transient to see a "void variable" when it runs.
;; Keep only a compile-time declaration so the byte-compiler is quiet without
;; registering the variable at runtime.
(eval-when-compile
  (defvar transient--prefix))

;;;; Section: Feature flags and “public” groups
;;
;; All user options live under the magpt group. The module is provider-agnostic and safe by default.

(defgroup magpt nil
  "MaGPT: Git/Magit AI assistant via gptel (commit messages and assist tasks)."
  :group 'tools
  :group 'vc
  :prefix "magpt-")

;;;; Section: Customization — core options
;;
;; These options control models, prompts, size limits, UX, and repo discovery.

(defcustom magpt-model nil
  "LLM model name for gptel. If nil, uses gptel’s currently-selected default."
  :type '(choice (const :tag "Use gptel default model" nil)
                 (string :tag "Explicit model name"))
  :group 'magpt)

(defcustom magpt-info-language "English"
  "Preferred natural language for informative content (summaries, rationales) in assist tasks.
Note: This does not translate Emacs UI; it only nudges the model via prompts."
  :type 'string
  :group 'magpt)

(defcustom magpt-commit-language "English"
  "Preferred language for generated commit messages. If nil, no preference."
  :type '(choice (const :tag "No preference" nil)
                 (string :tag "Language"))
  :group 'magpt)

(defcustom magpt-commit-prompt
  "You are an assistant that writes high-quality Git commit messages.
Requirements:
- Use Conventional Commits types when applicable (feat, fix, docs, refactor, test, chore, perf, build, ci).
- Subject (first line, <= 72 chars): state what was done (past/result form), not what to do; avoid infinitive/imperative. Prefer one high‑level, generalized summary when many files or heterogeneous changes are present; do not enumerate individual edits.
- Optional body: wrap at ~72 chars per line; explain motivation, context, and impact.
- Do not include ticket/issue references unless present in the diff or existing message.
- If the diff is empty or unclear, say 'chore: update' with a brief rationale.
Provide the final commit message only, no extra commentary."
  "Prompt template for commit message generation. The diff is appended."
  :type 'string
  :group 'magpt)

(defcustom magpt-max-diff-bytes 200000
  "Maximum UTF-8 byte size for the diff sent to the model.
If nil, no limit. When truncated, boundaries respect UTF-8 and a note is added."
  :type '(choice (const :tag "No limit" nil)
                 (integer :tag "Max bytes"))
  :group 'magpt)

(defcustom magpt-insert-into-commit-buffer t
  "If non-nil, insert generated commit messages into the commit buffer when available.
Otherwise show results in a separate read-only buffer."
  :type 'boolean
  :group 'magpt)

(defcustom magpt-project-root-strategy 'prefer-magit
  "Strategy for determining the Git project root:
- prefer-magit    : Magit → VC → project.el → default-directory check
- prefer-vc       : VC → Magit → project.el → default-directory check
- prefer-project  : project.el → Magit → VC → default-directory check"
  :type '(choice
          (const :tag "Prefer Magit" prefer-magit)
          (const :tag "Prefer VC" prefer-vc)
          (const :tag "Prefer project.el" prefer-project))
  :group 'magpt)

(defcustom magpt-diff-args '("--staged" "--no-color")
  "Additional arguments used with git diff when collecting staged changes."
  :type '(repeat string)
  :group 'magpt)

(defcustom magpt-confirm-before-send t
  "If non-nil, ask for confirmation before sending content to the model."
  :type 'boolean
  :group 'magpt)

(defcustom magpt-allow-apply-safe-ops t
  "If non-nil, enable safe apply operations (e.g., stage/unstage whole files) via Magit buttons or commands.
This gates any mutation-producing Apply actions; Phase 2 enables only naturally reversible operations."
  :type 'boolean
  :group 'magpt)

;;;; Section: Project RC (.magptrc) support
;;
;; Per-project overrides with highest priority. The file format is a safe “alist” of (SYMBOL . VALUE).

(defcustom magpt-rc-file-name ".magptrc"
  "Per-project RC file name at the repo root. Overrides user options when present."
  :type 'string
  :group 'magpt)

(defcustom magpt-user-rc-file (expand-file-name "~/.magptrc")
  "Path to user-level magpt RC file. Loaded before project RC; project overrides."
  :type '(choice (const :tag "Disabled" nil)
                 (file :tag "RC file path"))
  :group 'magpt)

(defvar magpt--user-rc-state nil
  "Internal cache of user rc: plist (:path PATH :mtime TIME :data ALIST).")

(defvar magpt--proj-rc-state nil
  "Internal cache of project rc: plist (:path PATH :mtime TIME :data ALIST).")

(defun magpt--locate-project-rc ()
  "Return absolute path to project .magptrc if found; otherwise nil."
  (let ((root (ignore-errors (magpt--project-root))))
    (when root
      (let ((f (expand-file-name magpt-rc-file-name root)))
        (when (file-exists-p f) f)))))

;; Backward-compat alias (older code may expect this name).
(defun magpt--locate-rc ()
  "Return absolute path to project .magptrc if found; otherwise nil."
  (magpt--locate-project-rc))

(defun magpt--locate-user-rc ()
  "Return absolute path to user RC file if configured and exists; otherwise nil."
  (when (and magpt-user-rc-file (stringp magpt-user-rc-file))
    (let ((f (expand-file-name magpt-user-rc-file)))
      (when (file-exists-p f) f))))

(defun magpt--read-rc (file)
  "Read FILE and return an alist of (SYMBOL . VALUE). Ignores arbitrary code; supports quoted list."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((sexp (read (current-buffer))))
          (when (and (listp sexp) (eq (car-safe sexp) 'quote))
            (setq sexp (cadr sexp)))
          (when (listp sexp) sexp)))
    (error
     (magpt--log "rc read error: %s: %s" file (error-message-string err))
     nil)))

(defun magpt--apply-rc (alist)
  "Apply ALIST of (SYMBOL . VALUE) to magpt variables. Highest priority overrides."
  (when (listp alist)
    (dolist (kv alist)
      (pcase kv
        (`(,k . ,v)
         (let* ((sym (cond
                      ((symbolp k) k)
                      ((stringp k) (intern k))
                      (t nil))))
           (when (and sym
                      (string-prefix-p "magpt-" (symbol-name sym))
                      (boundp sym))
             (set sym v))))))))

(defun magpt--maybe-load-user-rc ()
  "Load and apply user RC (~/.magptrc) if present and changed."
  (let ((f (magpt--locate-user-rc)))
    (when f
      (let* ((attr (file-attributes f))
             (mtime (when attr (file-attribute-modification-time attr))))
        (when (or (null magpt--user-rc-state)
                  (not (equal (plist-get magpt--user-rc-state :path) f))
                  (not (equal (plist-get magpt--user-rc-state :mtime) mtime)))
          (let ((alist (magpt--read-rc f)))
            (setq magpt--user-rc-state (list :path f :mtime mtime :data alist))
            (magpt--apply-rc alist)
            (magpt--log "user rc loaded: %s keys=%s"
                        f (mapcar (lambda (kv)
                                    (cond
                                     ((consp kv) (symbol-name (car kv)))
                                     ((symbolp kv) (symbol-name kv))
                                     (t (format "%S" kv))))
                                  (or alist '())))))))))

(defun magpt--maybe-load-project-rc ()
  "Load and apply project .magptrc if present and changed. Clear cached state when absent."
  (let ((f (magpt--locate-project-rc)))
    (if (not f)
        (setq magpt--proj-rc-state nil)
      (let* ((attr (file-attributes f))
             (mtime (when attr (file-attribute-modification-time attr))))
        (when (or (null magpt--proj-rc-state)
                  (not (equal (plist-get magpt--proj-rc-state :path) f))
                  (not (equal (plist-get magpt--proj-rc-state :mtime) mtime)))
          (let ((alist (magpt--read-rc f)))
            (setq magpt--proj-rc-state (list :path f :mtime mtime :data alist))
            (magpt--apply-rc alist)
            (magpt--log "project rc loaded: %s keys=%s"
                        f (mapcar (lambda (kv)
                                    (cond
                                     ((consp kv) (symbol-name (car kv)))
                                     ((symbolp kv) (symbol-name kv))
                                     (t (format "%S" kv))))
                                  (or alist '())))))))))

(defun magpt--maybe-load-rc ()
  "Load and apply user RC then project RC; project overrides user.
Project RC is always re-applied last to ensure precedence even when only the
user RC changed since the last call."
  ;; Load user-level first to establish defaults.
  (magpt--maybe-load-user-rc)
  ;; Then load project-level, which takes precedence.
  (magpt--maybe-load-project-rc)
  ;; Re-apply project RC data (only if it belongs to the CURRENT project) to enforce precedence consistently.
  (let ((curr (magpt--locate-project-rc)))
    (when (and magpt--proj-rc-state
               (plist-get magpt--proj-rc-state :data)
               (equal (plist-get magpt--proj-rc-state :path) curr))
      (magpt--apply-rc (plist-get magpt--proj-rc-state :data)))))

;;;; Section: Logging and diagnostics
;;
;; Diagnostics are lightweight and safe. Use magpt-show-log to open the buffer.

(defcustom magpt-log-enabled t
  "If non-nil, write diagnostic logs to `magpt-log-buffer-name'."
  :type 'boolean
  :group 'magpt)

(defcustom magpt-log-buffer-name "*magpt-log*"
  "Name of the buffer used for diagnostic logs."
  :type 'string
  :group 'magpt)

(defun magpt--log (fmt &rest args)
  "Append a diagnostic line to `magpt-log-buffer-name' and echo minimal info."
  (when (and (boundp 'magpt-log-enabled) magpt-log-enabled)
    (let ((buf (get-buffer-create (if (boundp 'magpt-log-buffer-name)
                                      magpt-log-buffer-name
                                    "*magpt-log*"))))
      (with-current-buffer buf
        (goto-char (point-max))
        (let* ((ts (format-time-string "%Y-%m-%d %H:%M:%S"))
               (line (condition-case lerr
                         (apply #'format fmt args)
                       (error
                        (format "LOG-FMT-ERROR: fmt=%S args=%S err=%s"
                                fmt args (error-message-string lerr))))))
          (insert (format "[%s] %s\n" ts line)))))))

(defun magpt--backtrace-string ()
  "Return current backtrace as a string (best-effort)."
  (condition-case _
      (with-output-to-string (backtrace))
    (error "<no-backtrace>")))

;;;###autoload
(defun magpt-show-log ()
  "Open the magpt diagnostic log buffer."
  (interactive)
  (pop-to-buffer (get-buffer-create magpt-log-buffer-name)))

;;;; Section: i18n helpers (messages for UI and overview)
;;
;; i18n moved into its own module to support more languages.
(require 'magpt-i18n nil t)


;;;; Section: Size control and prompt building
;;
;; We enforce UTF-8-safe truncation and build final prompts with clear markers.

(defun magpt--confirm-send (orig-bytes send-bytes)
  "Ask the user to confirm sending content of SEND-BYTES (showing ORIG-BYTES for context)."
  (if (not magpt-confirm-before-send)
      t
    (let ((msg (if (= orig-bytes send-bytes)
                   (magpt--i18n 'confirm-send-full send-bytes)
                 (magpt--i18n 'confirm-send-trunc orig-bytes send-bytes))))
      (magpt--log "confirm-send: info-lang=%S msg=%s" magpt-info-language msg)
      (y-or-n-p msg))))

;;;; Section: Task registry (experimental core abstraction)
;;
;; A Task encodes a flow: context → prompt → request → render/apply. This is the foundation
;; for the evolving assistant features beyond commit messages. It is optional and off by default.

(defcustom magpt-enable-task-registry t
  "If non-nil, expose experimental task registry commands (assist tasks; AI overview)."
  :type 'boolean
  :group 'magpt)

(cl-defstruct (magpt-task (:constructor magpt--task))
  "Task object holding necessary functions and metadata for execution."
  name title scope context-fn prompt-fn render-fn apply-fn confirm-send?)

(defvar magpt--tasks (make-hash-table :test 'eq)
  "Registry of magpt tasks keyed by symbol.")

(defun magpt--hash-table-keys (ht)
  "Return a list of keys in hash-table HT."
  (let (ks) (maphash (lambda (k _v) (push k ks)) ht) (nreverse ks)))

(defun magpt-register-task (task)
  "Register TASK (a `magpt-task' struct) in the registry."
  (puthash (magpt-task-name task) task magpt--tasks))

(defun magpt--safe-errstr (err)
  "Return a human-friendly string for ERR without throwing."
  (or (ignore-errors
        (if (fboundp 'magpt--errstr)
            (magpt--errstr err)
          (error-message-string err)))
      "<no-error-object>"))

(defun magpt--task-collect-context (task ctx)
  "Collect context for TASK using its context-fn and return (DATA PREVIEW BYTES)."
  (magpt--log "run-task: %s collecting context..." (magpt-task-name task))
  (funcall (magpt-task-context-fn task) ctx))

(defun magpt--task-build-prompt (task data bytes)
  "Build prompt for TASK from DATA; BYTES used for logging."
  (magpt--log "run-task: %s building prompt (bytes=%s)..." (magpt-task-name task) (or bytes -1))
  (funcall (magpt-task-prompt-fn task) data))

(defun magpt--task-should-skip-p (bytes)
  "Return non-nil when BYTES indicate an empty/zero-sized context."
  (and (or (null bytes) (zerop bytes))))

(defun magpt--task-confirm-send (task bytes)
  "Return t if sending should proceed for TASK with BYTES."
  (if (magpt-task-confirm-send? task)
      (magpt--confirm-send bytes bytes)
    t))

(defun magpt--task-handle-callback (task out data)
  "Handle successful TASK callback with OUT string and DATA.
Ensure history storage is available to avoid void-variable on append."
  ;; Make sure history storage is loaded and base variable is bound.
  (unless (boundp 'magpt--history-entries)
    (require 'magpt-history nil t)
    (unless (boundp 'magpt--history-entries)
      (defvar magpt--history-entries nil)))
  (funcall (magpt-task-render-fn task) out data)
  (when (magpt-task-apply-fn task)
    (funcall (magpt-task-apply-fn task) out data)))

(defun magpt--task-dispatch (task prompt data bytes)
  "Dispatch PROMPT for TASK and handle async callback; DATA/BYTES for logging."
  (let ((gptel-model (or magpt-model gptel-model)))
    (magpt--log "run-task: %s bytes=%d info-lang=%S commit-lang=%S prompt-preview=%s"
                (magpt-task-name task) (or bytes -1) magpt-info-language magpt-commit-language
                (let ((n (min 180 (length prompt)))) (substring prompt 0 n)))
    (message "magpt: requesting %s..." (magpt-task-name task))
    (condition-case gerr
        (let ((sys (pcase (magpt-task-name task)
                     ((or 'stage-by-intent-hunks 'resolve-conflict-here) nil)
                     (_ (magpt--system-prompt 'info)))))
          (magpt--gptel-request
           prompt
           :system sys
           :callback
           (lambda (resp info)
             (ignore info)
             (let ((magpt--current-request prompt))
               (condition-case e2
                   (let* ((out (string-trim (magpt--response->string resp)))
                          ;; Используем тот же санитайзер, что и история, чтобы статус в минибуфере
                          ;; соответствовал реальности (strip fenced JSON и пр.)
                          (san (if (fboundp 'magpt--sanitize-response)
                                   (magpt--sanitize-response out)
                                 out))
                          (name (magpt-task-name task)))
                     (magpt--log "task-callback: %s resp-type=%S bytes=%d preview=%s"
                                 name (type-of resp) (length out)
                                 (substring out 0 (min 180 (length out))))
                     (magpt--task-handle-callback task out data)
                     ;; User-visible outcome message: JSON OK / not JSON / empty (по san)
                     (cond
                      ((or (not (stringp san)) (string-empty-p san))
                       (message "%s" (magpt--i18n 'task-empty-response2 name)))
                      ((condition-case _ (progn (json-parse-string san) t)
                         (error nil))
                       (message "%s" (magpt--i18n 'task-done-json-ok name)))
                      (t
                       (message "%s" (magpt--i18n 'task-done-json-invalid name)))))
                 (error
                  (let* ((err e2)
                         (emsg (magpt--safe-errstr err)))
                    (magpt--log "task-callback exception: %s" emsg)
                    (magpt--log "task-callback exception (raw): %S" err)
                    (magpt--log "task-callback exception: BT:\n%s" (magpt--backtrace-string))
                    ;; Append an error entry so Overview reflects the failure
                    (ignore-errors
                      (magpt--history-append-error-safe (magpt-task-name task)
                                                        (or magpt--current-request "")
                                                        emsg))
                    (ignore-errors
                      (message "%s"
                               (or (condition-case _
                                       (magpt--i18n 'callback-error emsg)
                                     (error (format "magpt: callback error: %s" emsg)))
                                   (format "magpt: callback error: %s" emsg))))))))))
          (magpt--log "run-task: %s dispatched to gptel OK" (magpt-task-name task)))
      (error
       (let ((emsg (magpt--safe-errstr gerr)))
         ;; Record error in history so user sees a card even if callback never arrives.
         (ignore-errors
           (magpt--history-append-error-safe (magpt-task-name task) prompt emsg))
         ;; Log only; do not message the user here — async callback may still arrive.
         (magpt--log "gptel-request error for %s: %s\nBT:\n%s"
                     (magpt-task-name task)
                     emsg
                     (magpt--backtrace-string)))))))

(defun magpt--handle-run-task-exception (err)
  "Log and surface a user-friendly message for ERR raised during magpt--run-task."
  (let ((emsg (magpt--safe-errstr err)))
    (magpt--log "run-task exception: %s" emsg)
    (magpt--log "run-task exception (raw): %S" err)
    (magpt--log "run-task exception: BT:\n%s" (magpt--backtrace-string))
    (ignore-errors
      (message "%s"
               (or (condition-case _
                       (magpt--i18n 'callback-error emsg)
                     (error (format "magpt: callback error: %s" emsg)))
                   (format "magpt: callback error: %s" emsg))))))

(defun magpt--run-task (task &optional ctx)
  "Run TASK: collect context, build prompt, request model, then render/apply."
  (magpt--log "run-task: START name=%s buffer=%s root=%s"
              (magpt-task-name task)
              (buffer-name)
              (ignore-errors (magpt--project-root)))
  (condition-case e
      (pcase-let* ((`(,data ,_preview ,bytes)
                    (magpt--task-collect-context task ctx))
                   (prompt
                    (magpt--task-build-prompt task data bytes)))
        (if (magpt--task-should-skip-p bytes)
            (let ((name (magpt-task-name task)))
              (magpt--log "run-task: %s skipped (empty context)" name)
              (message "magpt: nothing to send for %s (empty context)" name))
          (when (magpt--task-confirm-send task bytes)
            (magpt--task-dispatch task prompt data bytes))))
    (error
     (magpt--handle-run-task-exception e))))

;;;###autoload
(defun magpt-run-task (name &optional ctx)
  "Interactively run a registered magpt task NAME. Experimental."
  (interactive
   (progn
     (unless magpt-enable-task-registry
       (user-error "Enable `magpt-enable-task-registry' to use experimental tasks"))
     (magpt--register-assist-tasks)
     (magpt--register-recommend-tasks)
     (list (intern (completing-read
                    "magpt task: "
                    (mapcar #'symbol-name (magpt--hash-table-keys magpt--tasks)))))))
  (magpt--maybe-load-rc)
  (when magpt-enable-task-registry
    (magpt--register-assist-tasks)
    (magpt--register-recommend-tasks))
  (magpt--log "run-task: pre-lookup name=%s tasks=%s"
              name (mapcar #'symbol-name (magpt--hash-table-keys magpt--tasks)))
  (let ((task (gethash name magpt--tasks)))
    (unless task
      (magpt--log "run-task: UNKNOWN task=%s (registry empty? %s)"
                  name (if (null (magpt--hash-table-keys magpt--tasks)) "t" "nil"))
      (user-error "Unknown magpt task: %s" name))
    (magpt--run-task task ctx)))

;;;; Section: History storage (read-only; used by AI Overview)
;;
;; A shared place to append prompts/responses and validity hints; visible in the Magit AI Overview.

(defvar magpt-history-changed-hook nil
  "Hook run after a history entry is appended.
UI modules (e.g., Magit overview) can subscribe to refresh themselves.")

(defun magpt--history-append-error-safe (task request emsg)
  "Append an error entry to history safely (no throw if history is not ready).
TASK is a symbol; REQUEST is a string; EMSG is an error string."
  (condition-case _e
      (progn
        ;; Ensure history feature/variable exist
        (unless (boundp 'magpt--history-entries)
          (require 'magpt-history nil t)
          (unless (boundp 'magpt--history-entries)
            (defvar magpt--history-entries nil)))
        (when (fboundp 'magpt--history-append-entry)
          (magpt--history-append-entry task (or request "") ""
                                       "Error: see :error"
                                       :valid nil :error (or emsg ""))))
    (error
     ;; Last resort: just log; avoid rethrowing inside callbacks.
     (magpt--log "history-append-error-safe: could not append error for %s: %s"
                 task emsg))))

(require 'magpt-history) ;; AI history storage (entries, append, search)

(defcustom magpt-ui-density 'regular
  "UI density profile (affects AI overview): 'regular or 'compact.
In compact mode, long lists are truncated (with hints) and spacing is reduced."
  :type '(choice (const :tag "Regular" regular)
                 (const :tag "Compact" compact))
  :group 'magpt)

(defcustom magpt-overview-compact-max-risks 3
  "Max number of risks to show in compact density for explain-status (AI overview)."
  :type 'integer
  :group 'magpt)

(defcustom magpt-overview-compact-max-suggestions 3
  "Max number of suggestions to show in compact density for explain-status (AI overview)."
  :type 'integer
  :group 'magpt)

(defface magpt-badge-info-face
  '((t :inherit shadow))
  "Neutral/info badge face (e.g., repo/branch chips) in overview header."
  :group 'magpt)

;; -----------------------------------------------------------------------------
;; Soft restart (safe reload) to recover after re-evaluations or partial loads.
;; Disables magpt-mode, removes hooks/advices, unloads magpt subfeatures,
;; reloads modules in dependency order, then re-enables magpt-mode.

(defun magpt--unload-feature-safe (feat)
  "Unload FEAT if loaded; ignore errors."
  (when (featurep feat)
    (ignore-errors (unload-feature feat t))))

(defun magpt--cleanup-hooks-advices ()
  "Remove hooks/advices installed by magpt integration (best-effort)."
  (ignore-errors (remove-hook 'magpt-history-changed-hook #'magpt--refresh-magit-status-visible))
  (ignore-errors (remove-hook 'magpt-history-changed-hook #'magpt--ai-actions-history-updated))
  (ignore-errors (remove-hook 'magit-status-sections-hook #'magpt-magit-insert-ai-overview))
  ;; Also remove 'extras' section if it was enabled earlier, чтобы она не всплывала сверху.
  (ignore-errors (remove-hook 'magit-status-sections-hook #'magpt-overview-extras-insert))
  ;; Debug advices (if were enabled)
  (when (fboundp 'advice-remove)
    (ignore-errors (advice-remove 'magit-refresh #'magpt--log-magit-refresh))
    (ignore-errors (advice-remove 'magit-refresh-buffer #'magpt--log-magit-refresh))
    (ignore-errors (advice-remove 'magit-section-show #'magpt--log-magit-section-show))
    (ignore-errors (advice-remove 'magit-section-hide #'magpt--log-magit-section-show))
    (ignore-errors (advice-remove 'magit-section-toggle #'magpt--log-magit-section-show))))

;;;###autoload
(defun magpt-restart ()
  "Soft-reload MaGPT and its Magit/Transient integration safely.
Use when transient/ui ломается после пересборки или eval-buffer."
  (interactive)
  (let ((was-enabled (and (boundp 'magpt-mode) magpt-mode)))
    ;; 1) Disable integration to detach keys/hooks
    (when was-enabled (ignore-errors (magpt-mode -1)))
    ;; 2) Cleanup hooks/advices
    (magpt--cleanup-hooks-advices)
    ;; 3) Unload magpt subfeatures only (keep core 'magpt' and external deps)
    (dolist (feat '(magpt-transient
                    magpt-magit-overview
                    magpt-apply
                    magpt-commit
                    magpt-tasks-resolve
                    magpt-tasks-recommend
                    magpt-tasks-assist
                    magpt-tasks-core
                    magpt-ui-preview
                    magpt-history
                    magpt-gpt
                    magpt-git
                    magpt-i18n))
      (magpt--unload-feature-safe feat))
    ;; 4) Ensure external deps present (avoid void-variable/void-function)
    (require 'gptel nil t)      ;; binds gptel-model, etc.
    (require 'magit nil t)
    (require 'transient nil t)
    ;; 5) Reload modules in dependency order
    (dolist (feat '(magpt-i18n
                    magpt-history
                    magpt-ui-preview
                    magpt-git
                    magpt-gpt
                    magpt-apply
                    magpt-tasks-core
                    magpt-tasks-assist
                    magpt-tasks-recommend
                    magpt-tasks-resolve
                    magpt-magit-overview
                    magpt-transient
                    magpt-commit))
      (require feat nil t))
    ;; 6) Re-enable mode if it was enabled
    (when was-enabled (ignore-errors (magpt-mode 1)))
    ;; 7) Nudge redisplay/Magit
    (ignore-errors (force-mode-line-update t))
    (when (and (featurep 'magit) (fboundp 'magit-refresh))
      (run-at-time 0 nil (lambda () (ignore-errors (magit-refresh)))))
    (message "magpt: restarted")))

;; Ensure logging and stability wrappers are loaded early.
(require 'magpt-log)
(require 'magpt-stability)
(defcustom magpt-overview-extras-enabled nil
  "If non-nil, insert extra AI overview cards (\"More\") in magit-status."
  :type 'boolean
  :group 'magpt)
(require 'magpt-overview-extras nil t)
(if (and magpt-overview-extras-enabled
         (fboundp 'magpt-overview-extras-enable))
    (magpt-overview-extras-enable)
  ;; Ensure the extras section is not shown when disabled (remove hook if present).
  (when (fboundp 'magpt-overview-extras-insert)
    (ignore-errors
      (remove-hook 'magit-status-sections-hook #'magpt-overview-extras-insert))))

(provide 'magpt)

;;; magpt.el ends here
