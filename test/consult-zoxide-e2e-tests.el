;;; consult-zoxide-e2e-tests.el --- End-to-end tests against a real zoxide -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  These drive the actual zoxide and git binaries.  Every spec points
;;  `_ZO_DATA_DIR' at a throwaway directory, so the database under test is
;;  created and destroyed with the spec and the real one is never opened,
;;  let alone written to.  The suite skips itself where the binaries are
;;  missing.
;;
;;  What the unit tests cannot cover lives here: that the flags handed to
;;  zoxide mean what the code assumes, that removal really removes, that
;;  the guard really leaves the database alone, and that the HEAD parser
;;  agrees with git about which branch is out.
;;
;;; Code:

(require 'buttercup)
(require 'dired)
(require 'consult-zoxide)

(defvar consult-zoxide-e2e--env nil)
(defvar consult-zoxide-e2e--data nil)
(defvar consult-zoxide-e2e--work nil)

(defun consult-zoxide-e2e--dir (name)
  "Create NAME under the scratch tree and return its true name."
  (let ((dir (expand-file-name name consult-zoxide-e2e--work)))
    (make-directory dir t)
    (directory-file-name (file-truename dir))))

(defun consult-zoxide-e2e--add (&rest dirs)
  "Teach the sandbox database about DIRS."
  (dolist (dir dirs)
    (with-temp-buffer
      (unless (zerop (consult-zoxide--call t "add" dir))
        (error "zoxide add failed: %s" (string-trim (buffer-string)))))))

(defun consult-zoxide-e2e--paths (&optional include-dead)
  "Return just the paths the sandbox database holds."
  (mapcar #'car (consult-zoxide--query nil include-dead)))

(defun consult-zoxide-e2e--git (dir &rest args)
  "Run git in DIR with ARGS and return its trimmed output."
  (with-temp-buffer
    ;; let*, not let: default-directory has to be in effect before
    ;; call-process runs, or git operates on whatever directory Emacs
    ;; happens to be in
    (let* ((default-directory (file-name-as-directory dir))
           (status (apply #'call-process "git" nil t nil
                          "-c" "user.email=e2e@example.invalid"
                          "-c" "user.name=e2e"
                          "-c" "commit.gpgsign=false"
                          "-c" "init.defaultBranch=main"
                          args)))
      (unless (zerop status)
        (error "git %S failed: %s" args (string-trim (buffer-string)))))
    (string-trim (buffer-string))))

(defun consult-zoxide-e2e--repo (name)
  "Create a git repository NAME with one commit, and return its path."
  (let ((dir (consult-zoxide-e2e--dir name)))
    (consult-zoxide-e2e--git dir "init" "--quiet" "-b" "main" ".")
    (with-temp-file (expand-file-name "seed" dir) (insert "seed\n"))
    (consult-zoxide-e2e--git dir "add" "seed")
    (consult-zoxide-e2e--git dir "commit" "--quiet" "-m" "seed")
    dir))

(describe "consult-zoxide against a real zoxide database"
  (before-each
    (assume (executable-find "zoxide") "zoxide is not installed")
    (assume (executable-find "git") "git is not installed")
    (setq consult-zoxide-e2e--data (make-temp-file "czox-e2e-data" t))
    (setq consult-zoxide-e2e--work (make-temp-file "czox-e2e-work" t))
    (setq consult-zoxide-e2e--env process-environment)
    ;; every zoxide call below lands in the throwaway database
    (setq process-environment
          (cons (format "_ZO_DATA_DIR=%s" consult-zoxide-e2e--data)
                process-environment)))

  (after-each
    (setq process-environment consult-zoxide-e2e--env)
    (delete-directory consult-zoxide-e2e--data t)
    (delete-directory consult-zoxide-e2e--work t))

  (describe "querying"
    (it "starts out empty, proving the sandbox is not the real database"
      (expect (consult-zoxide--query) :to-be nil))

    (it "returns what was added, with a score"
      (let ((one (consult-zoxide-e2e--dir "one")))
        (consult-zoxide-e2e--add one)
        (expect (consult-zoxide-e2e--paths) :to-equal (list one))
        (expect (cdar (consult-zoxide--query)) :to-be-greater-than 0)))

    (it "orders by frecency, not by insertion"
      (let ((cold (consult-zoxide-e2e--dir "cold"))
            (hot (consult-zoxide-e2e--dir "hot")))
        (consult-zoxide-e2e--add cold)
        (dotimes (_ 5) (consult-zoxide-e2e--add hot))
        (expect (consult-zoxide-e2e--paths) :to-equal (list hot cold))))

    (it "narrows through zoxide's own matcher when given a query"
      (let ((alpha (consult-zoxide-e2e--dir "alpha"))
            (beta (consult-zoxide-e2e--dir "beta")))
        (consult-zoxide-e2e--add alpha beta)
        (expect (mapcar #'car (consult-zoxide--query "alpha"))
                :to-equal (list alpha))))

    (it "reports nothing, rather than failing, when a query matches nothing"
      (consult-zoxide-e2e--add (consult-zoxide-e2e--dir "alpha"))
      (expect (consult-zoxide--query "zzzznope") :to-be nil))

    (it "hides a vanished directory until --all is asked for"
      (let ((gone (consult-zoxide-e2e--dir "gone")))
        (consult-zoxide-e2e--add gone)
        (delete-directory gone t)
        (expect (consult-zoxide-e2e--paths) :to-be nil)
        (expect (consult-zoxide-e2e--paths t) :to-equal (list gone)))))

  (describe "candidates"
    (it "tags a vanished directory dead"
      (let ((gone (consult-zoxide-e2e--dir "gone")))
        (consult-zoxide-e2e--add gone)
        (delete-directory gone t)
        (expect (get-text-property 0 'consult-zoxide-tags
                                   (car (consult-zoxide--candidates nil t)))
                :to-equal '(dead))))

    (it "tags a real checkout and agrees with git about the branch"
      (let ((repo (consult-zoxide-e2e--repo "repo")))
        (consult-zoxide-e2e--add repo)
        (let* ((cand (car (consult-zoxide--candidates)))
               (gitdir (get-text-property 0 'consult-zoxide-gitdir cand)))
          (expect (get-text-property 0 'consult-zoxide-tags cand) :to-equal '(git))
          (expect (consult-zoxide--branch gitdir)
                  :to-equal (consult-zoxide-e2e--git repo "symbolic-ref"
                                                     "--short" "HEAD")))))

    (it "agrees with git about a detached HEAD"
      (let ((repo (consult-zoxide-e2e--repo "detached")))
        (consult-zoxide-e2e--git repo "checkout" "--quiet" "--detach")
        (consult-zoxide-e2e--add repo)
        (let ((gitdir (get-text-property 0 'consult-zoxide-gitdir
                                         (car (consult-zoxide--candidates)))))
          (expect (consult-zoxide--branch gitdir)
                  :to-equal (concat "@" (substring
                                         (consult-zoxide-e2e--git repo "rev-parse" "HEAD")
                                         0 7))))))

    (it "tags a real worktree as both git and worktree"
      (let* ((repo (consult-zoxide-e2e--repo "main-repo"))
             (wt (expand-file-name "side" consult-zoxide-e2e--work)))
        (consult-zoxide-e2e--git repo "worktree" "add" "--quiet" "-b" "side" wt)
        (setq wt (directory-file-name (file-truename wt)))
        (consult-zoxide-e2e--add wt)
        (let ((cand (car (consult-zoxide--candidates))))
          (expect (get-text-property 0 'consult-zoxide-tags cand)
                  :to-equal '(git worktree))
          (expect (consult-zoxide--branch
                   (get-text-property 0 'consult-zoxide-gitdir cand))
                  :to-equal "side"))))

    (it "suppresses the branch of a worktree named after it"
      ;; the worktree-per-ticket layout, where the annotation is pure noise
      (let* ((repo (consult-zoxide-e2e--repo "ticket-repo"))
             (wt (expand-file-name "TICKET-42" consult-zoxide-e2e--work)))
        (consult-zoxide-e2e--git repo "worktree" "add" "--quiet" "-b" "TICKET-42" wt)
        (consult-zoxide-e2e--add (directory-file-name (file-truename wt)))
        (expect (substring-no-properties
                 (consult-zoxide--annotation (car (consult-zoxide--candidates))))
                :not :to-match "TICKET-42"))))

  (describe "removal"
    (it "really drops a single entry"
      (let ((one (consult-zoxide-e2e--dir "one"))
            (two (consult-zoxide-e2e--dir "two")))
        (consult-zoxide-e2e--add one two)
        (consult-zoxide-remove one)
        (expect (consult-zoxide-e2e--paths t) :to-equal (list two))))

    (it "drops a whole batch of vanished entries in one call"
      (let ((a (consult-zoxide-e2e--dir "a"))
            (b (consult-zoxide-e2e--dir "b"))
            (keep (consult-zoxide-e2e--dir "keep")))
        (consult-zoxide-e2e--add a b keep)
        (delete-directory a t)
        (delete-directory b t)
        (consult-zoxide-remove (list a b))
        (expect (consult-zoxide-e2e--paths t) :to-equal (list keep))))

    (it "refuses a bulk removal holding a live directory"
      (let ((gone (consult-zoxide-e2e--dir "gone"))
            (live (consult-zoxide-e2e--dir "live")))
        (consult-zoxide-e2e--add gone live)
        (delete-directory gone t)
        (expect (consult-zoxide-remove (list gone live)) :to-throw 'user-error)))

    (it "leaves the database completely intact when it refuses"
      ;; the whole point of the guard: a mis-narrowed act-all changes nothing
      (let ((gone (consult-zoxide-e2e--dir "gone"))
            (live (consult-zoxide-e2e--dir "live")))
        (consult-zoxide-e2e--add gone live)
        (delete-directory gone t)
        (ignore-errors (consult-zoxide-remove (list gone live)))
        (expect (sort (consult-zoxide-e2e--paths t) #'string<)
                :to-equal (sort (list gone live) #'string<))))

    (it "reports failure instead of pretending, for an entry it never held"
      (consult-zoxide-e2e--add (consult-zoxide-e2e--dir "one"))
      (expect (consult-zoxide-remove "/nowhere/at/all") :to-throw 'error))

    (it "prunes exactly the dead entries a d-narrowed session would collect"
      (let ((gone-a (consult-zoxide-e2e--dir "gone-a"))
            (gone-b (consult-zoxide-e2e--dir "gone-b"))
            (live (consult-zoxide-e2e--dir "live")))
        (consult-zoxide-e2e--add gone-a gone-b live)
        (delete-directory gone-a t)
        (delete-directory gone-b t)
        (let* ((consult--narrow ?d)
               (dead (seq-filter #'consult-zoxide--narrow-predicate
                                 (consult-zoxide--candidates nil t))))
          (expect (length dead) :to-equal 2)
          (consult-zoxide-remove dead))
        (expect (consult-zoxide-e2e--paths t) :to-equal (list live)))))

  (describe "tracking"
    (it "records the directory of a real dired buffer"
      (let* ((dir (consult-zoxide-e2e--dir "visited"))
             (buffer (dired-noselect dir)))
        (unwind-protect
            (with-current-buffer buffer (consult-zoxide-track))
          (kill-buffer buffer))
        (expect (consult-zoxide-e2e--paths) :to-equal (list dir))))

    (it "bumps the score of a directory it already knows"
      (let ((dir (consult-zoxide-e2e--dir "visited")))
        (consult-zoxide-e2e--add dir)
        (let ((before (cdar (consult-zoxide--query))))
          (consult-zoxide-e2e--add dir)
          (expect (cdar (consult-zoxide--query)) :to-be-greater-than before)))))

  (describe "the whole read path"
    (it "returns a real directory from a stubbed selection"
      (let ((one (consult-zoxide-e2e--dir "one"))
            (two (consult-zoxide-e2e--dir "two")))
        (consult-zoxide-e2e--add one two)
        (spy-on 'consult--read :and-call-fake (lambda (cands &rest _) (cadr cands)))
        (expect (file-directory-p (consult-zoxide-read)) :to-be-truthy)))

    (it "skips the prompt when a query singles one out"
      (let ((only (consult-zoxide-e2e--dir "singular")))
        (consult-zoxide-e2e--add only)
        (spy-on 'consult--read)
        (expect (consult-zoxide-read "singular") :to-equal only)
        (expect 'consult--read :not :to-have-been-called)))))

;;; consult-zoxide-e2e-tests.el ends here
