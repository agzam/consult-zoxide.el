;;; consult-zoxide.el --- Jump to zoxide directories with Consult -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: August 13, 2026
;; Version: 0.1.0
;; Keywords: convenience files tools
;; Homepage: https://github.com/agzam/consult-zoxide.el
;; Package-Requires: ((emacs "29.1") (consult "2.0"))
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Jump to any directory zoxide remembers, from a Consult prompt.
;;
;;   M-x consult-zoxide
;;
;; Entries keep zoxide's frecency order and are annotated with their score
;; and, for git checkouts, the branch that is currently out.  Narrowing
;; keys select subsets: `g' git checkout roots, `w' worktrees, `d' entries
;; whose directory no longer exists.
;;
;; A prefix argument lists the vanished entries too, which is how they get
;; pruned: narrow with `d', then `embark-act-all' the removal action.
;; Removal refuses to take more than one still-existing directory at a
;; time, so a mis-narrowed `embark-act-all' cannot empty the database.
;;
;; Embark integration lives in the optional `consult-zoxide-embark'
;; file, which registers itself as soon as Embark loads.
;;
;; `consult-zoxide-read' is the library entry point: it prompts and
;; returns a directory without visiting it, for callers such as an
;; Eshell `z' command.

;;; Code:

(require 'consult)
(require 'seq)
(require 'subr-x)

(defvar dired-directory)

(defgroup consult-zoxide nil
  "Jump to directories remembered by zoxide."
  :group 'convenience
  :prefix "consult-zoxide-")

(defcustom consult-zoxide-executable "zoxide"
  "Name of, or path to, the zoxide executable."
  :type 'string)

(defcustom consult-zoxide-annotate-branch t
  "Whether to annotate git checkout roots with the branch they have out.
The branch is read straight out of HEAD rather than by running git, and
only for the rows the completion UI has on screen, so the cost does not
scale with the size of the database."
  :type 'boolean)

(defcustom consult-zoxide-narrow
  '((?g git       "git repo")
    (?w worktree  "worktree")
    (?d dead      "dead"))
  "Narrowing configuration, as a list of (KEY TAG LABEL).
TAG is matched against the tags `consult-zoxide--candidates' attaches."
  :type '(repeat (list character symbol string)))

(defface consult-zoxide-dead
  '((t :inherit shadow :strike-through t))
  "Face for entries whose directory no longer exists.")

(defface consult-zoxide-score
  '((t :inherit completions-annotations))
  "Face for the frecency score annotation.")

(defface consult-zoxide-branch
  '((t :inherit font-lock-keyword-face))
  "Face for the git branch annotation.")

(defvar consult-zoxide--branch-cache nil
  "Branch memo for a single prompt, let-bound by `consult-zoxide-read'.
A prompt is too short-lived for a checkout to change under it, so going
out of scope is all the invalidation this needs.")


;;;; Talking to zoxide

(defun consult-zoxide--call (destination &rest args)
  "Run the zoxide executable with ARGS, sending output to DESTINATION.
Returns the exit status."
  (unless (executable-find consult-zoxide-executable)
    (error "Cannot find the `%s' executable" consult-zoxide-executable))
  (apply #'call-process consult-zoxide-executable nil destination nil args))

(defun consult-zoxide--query (&optional query include-dead)
  "Return an alist of (PATH . SCORE), most frecent first.
QUERY is passed to zoxide's own matcher.  INCLUDE-DEAD keeps entries
whose directory has since vanished, which zoxide otherwise filters out."
  (with-temp-buffer
    (let ((status (apply #'consult-zoxide--call t "query" "--list" "--score"
                         (append (and include-dead '("--all"))
                                 (and query (list query))))))
      ;; a query matching nothing exits non-zero, which is an empty result
      ;; here rather than a failure
      (unless (memq status '(0 1))
        (error "Zoxide query failed: %s" (string-trim (buffer-string)))))
    (goto-char (point-min))
    (let (entries)
      (while (re-search-forward "^ *\\([0-9.]+\\) +\\(.+\\)$" nil t)
        (push (cons (match-string-no-properties 2)
                    (string-to-number (match-string-no-properties 1)))
              entries))
      (nreverse entries))))


;;;###autoload
(defun consult-zoxide-directories (&optional query include-dead)
  "Return the directories zoxide remembers, most frecent first.
Handy for feeding another completion source, such as `consult-dir'.
QUERY and INCLUDE-DEAD are as in `consult-zoxide-read'."
  (mapcar #'car (consult-zoxide--query query include-dead)))


;;;; Git

(defun consult-zoxide--gitdir-link (file dir)
  "Return the gitdir named inside FILE, resolved against DIR.
Submodules name it relatively, so it only resolves against DIR."
  (with-temp-buffer
    (insert-file-contents-literally file nil 0 512)
    (goto-char (point-min))
    (when (looking-at "gitdir: \\(.+\\)")
      (expand-file-name (string-trim (match-string-no-properties 1)) dir))))

(defun consult-zoxide--git-root (dir)
  "Return (KIND . GITDIR) when DIR is the root of a git checkout.
KIND is `plain', `worktree' or `submodule'.  The latter two keep `.git'
as a file naming the real gitdir instead of as a directory."
  (let ((dot-git (expand-file-name ".git" dir)))
    (cond
     ((file-directory-p dot-git) (cons 'plain dot-git))
     ((file-regular-p dot-git)
      (when-let* ((target (consult-zoxide--gitdir-link dot-git dir)))
        (cons (cond
               ((string-match-p "/\\.git/worktrees/" target) 'worktree)
               ((string-match-p "/\\.git/modules/" target) 'submodule)
               (t 'plain))
              target))))))

(defun consult-zoxide--branch (gitdir)
  "Return the branch checked out in GITDIR, or @SHA when HEAD is detached."
  (let ((head (expand-file-name "HEAD" gitdir)))
    (when (file-readable-p head)
      (with-temp-buffer
        (insert-file-contents-literally head nil 0 256)
        (goto-char (point-min))
        (cond
         ((looking-at "ref: refs/heads/\\(.+\\)")
          (match-string-no-properties 1))
         ((looking-at "\\([[:xdigit:]]\\{7\\}\\)")
          (concat "@" (match-string-no-properties 1))))))))

(defun consult-zoxide--branch-for (candidate gitdir)
  "Return GITDIR's branch, memoized per prompt under CANDIDATE."
  (if consult-zoxide--branch-cache
      (with-memoization (gethash candidate consult-zoxide--branch-cache)
        (consult-zoxide--branch gitdir))
    (consult-zoxide--branch gitdir)))


;;;; Candidates

(defun consult-zoxide--candidates (&optional query include-dead)
  "Return propertized candidates for QUERY, INCLUDE-DEAD keeping gone dirs.
Each candidate carries its score, its narrowing tags and, for checkout
roots, the gitdir the branch annotation reads from."
  (mapcar
   (pcase-lambda (`(,path . ,score))
     ;; a remote path is left unexamined: stat-ing it would put network
     ;; latency into every redisplay
     (let* ((remote (file-remote-p path))
            (live (or remote (file-directory-p path)))
            (git (and live (not remote) (consult-zoxide--git-root path)))
            (tags (delq nil (list (and (not live) 'dead)
                                  (and git 'git)
                                  (and (eq (car git) 'worktree) 'worktree)))))
       (let ((candidate (propertize path
                                    'consult-zoxide-score score
                                    'consult-zoxide-tags tags
                                    'consult-zoxide-gitdir (cdr git))))
         (unless live
           (add-face-text-property 0 (length candidate)
                                   'consult-zoxide-dead nil candidate))
         candidate)))
   (consult-zoxide--query query include-dead)))

(defun consult-zoxide--annotation (candidate)
  "Return the annotation text for CANDIDATE, without alignment padding."
  (when-let* ((score (get-text-property 0 'consult-zoxide-score candidate)))
    (let* ((gitdir (and consult-zoxide-annotate-branch
                        (get-text-property 0 'consult-zoxide-gitdir candidate)))
           (branch (and gitdir (consult-zoxide--branch-for candidate gitdir)))
           ;; a worktree is normally named after its branch, and echoing
           ;; that back puts a column of noise on every worktree row
           (branch (unless (equal branch (file-name-nondirectory candidate))
                     branch)))
      (concat (and branch (propertize (concat branch "  ")
                                      'face 'consult-zoxide-branch))
              (propertize (format "%6.1f" score) 'face 'consult-zoxide-score)))))

(defun consult-zoxide--annotate (candidate)
  "Return CANDIDATE's annotation, right-aligned against the window edge."
  (when-let* ((text (consult-zoxide--annotation candidate)))
    (concat (propertize " " 'display
                        `(space :align-to (- right ,(1+ (string-width text)))))
            text)))

(defun consult-zoxide--narrow-predicate (candidate)
  "Keep CANDIDATE when it carries the tag `consult--narrow' selects."
  (or (null consult--narrow)
      (memq (nth 1 (assq consult--narrow consult-zoxide-narrow))
            (get-text-property 0 'consult-zoxide-tags candidate))))


;;;; Commands

;;;###autoload
(defun consult-zoxide-read (&optional query include-dead)
  "Prompt for a directory zoxide remembers and return it.
QUERY is handed to zoxide's own matcher and, when it singles out exactly
one directory, the prompt is skipped - the shell `z' contract.
INCLUDE-DEAD lists entries whose directory has vanished; they are left
out by default, being nothing but noise unless the point is to prune
them."
  (let* ((consult-zoxide--branch-cache (make-hash-table :test #'equal))
         (candidates (consult-zoxide--candidates query include-dead)))
    (unless candidates
      (user-error "No zoxide entries%s" (if query (format " for %S" query) "")))
    (substring-no-properties
     (if (length= candidates 1)
         (car candidates)
       (consult--read
        candidates
        :prompt "Directory: "
        :category 'consult-zoxide-dir
        :sort nil
        :annotate #'consult-zoxide--annotate
        :narrow (list :predicate #'consult-zoxide--narrow-predicate
                      :keys (mapcar (lambda (entry)
                                      (cons (car entry) (nth 2 entry)))
                                    consult-zoxide-narrow))
        :initial query)))))

;;;###autoload
(defun consult-zoxide (&optional include-dead)
  "Jump to a directory zoxide remembers.
With a prefix argument, INCLUDE-DEAD also lists entries whose directory
is gone, so that narrowing to `d' collects them for removal."
  (interactive "P")
  (find-file (consult-zoxide-read nil include-dead)))

;;;###autoload
(defun consult-zoxide-remove (paths)
  "Drop PATHS from the zoxide database.

Refuses any bulk removal that includes a directory which still exists.
Bulk removal is for pruning entries whose directory is gone; without the
guard a mis-narrowed `embark-act-all' would empty the database in one
keystroke, and re-adding a path restores neither its score nor its
recorded access time."
  (let* ((paths (mapcar #'substring-no-properties (ensure-list paths)))
         (live (seq-filter (lambda (path)
                             (or (file-remote-p path) (file-directory-p path)))
                           paths)))
    (unless paths
      (user-error "No paths to remove"))
    (when (and (< 1 (length paths)) live)
      (user-error "Refusing to remove %d live %s in bulk; remove one at a time"
                  (length live)
                  (if (length= live 1) "directory" "directories")))
    (with-temp-buffer
      ;; zoxide validates every path before it writes anything, so a
      ;; non-zero exit means the database was left untouched
      (unless (zerop (apply #'consult-zoxide--call t "remove" paths))
        (error "Zoxide remove failed: %s" (string-trim (buffer-string)))))
    (message "Removed %d zoxide %s" (length paths)
             (if (length= paths 1) "entry" "entries"))))


;;;; Tracking

;;;###autoload
(defun consult-zoxide-track ()
  "Teach zoxide about the current buffer's directory."
  (interactive)
  (when-let* ((dir (if (derived-mode-p 'dired-mode)
                       (and (stringp dired-directory) dired-directory)
                     (and buffer-file-name
                          (file-name-directory buffer-file-name))))
              ((not (file-remote-p dir)))
              ((file-readable-p dir)))
    (with-temp-buffer
      (consult-zoxide--call t "add" (expand-file-name dir)))))

;;;###autoload
(define-minor-mode consult-zoxide-track-mode
  "Record directories visited in Dired into the zoxide database.
Only Dired is hooked.  `consult-zoxide-track' works in file buffers too,
but putting it on `find-file-hook' records the directory of every file
you open, which fills the database faster than it is worth."
  :global t
  :group 'consult-zoxide
  (if consult-zoxide-track-mode
      (add-hook 'dired-after-readin-hook #'consult-zoxide-track)
    (remove-hook 'dired-after-readin-hook #'consult-zoxide-track)))

;;;; consult-dir

(defvar consult-dir-sources)

(defvar consult-zoxide-directory-source
  `( :name     "Zoxide"
     :narrow   ?z
     :category file
     :face     consult-file
     :enabled  ,(lambda () (executable-find consult-zoxide-executable))
     :items    consult-zoxide-directories)
  "Zoxide source for `consult-dir-sources'.
Appended as soon as `consult-dir' loads, so it needs no setting up.")

;;;###autoload
(defun consult-zoxide-consult-dir-register ()
  "Append the zoxide source to `consult-dir-sources'."
  (add-to-list 'consult-dir-sources 'consult-zoxide-directory-source t))

;; Same arrangement as the Embark integration: the cookie copies this into
;; the generated autoloads, so the source appears for anyone who has
;; `consult-dir' without a manual require, and nothing here loads until
;; `consult-dir' itself does.
;;;###autoload
(with-eval-after-load 'consult-dir
  (consult-zoxide-consult-dir-register))

(provide 'consult-zoxide)
;;; consult-zoxide.el ends here
