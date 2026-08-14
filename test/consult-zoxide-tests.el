;;; consult-zoxide-tests.el --- Tests for consult-zoxide.el -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Unit tests for consult-zoxide.  Nothing here runs the zoxide binary;
;;  `consult-zoxide--call' is stubbed throughout.  The git helpers do work
;;  against real files, because the layouts they parse (a worktree's `.git'
;;  file, a submodule's relative gitdir) are the whole point of them.
;;
;;; Code:

(require 'buttercup)
(require 'dired)
(require 'consult-zoxide)

(defvar consult-zoxide-tests--tmp nil
  "Scratch directory for the specs that need real files.")

(defun consult-zoxide-tests--dir (&rest segments)
  "Create and return SEGMENTS as a directory under the scratch dir."
  (let ((dir (expand-file-name (string-join segments "/")
                               consult-zoxide-tests--tmp)))
    (make-directory dir t)
    dir))

(defun consult-zoxide-tests--write (file contents)
  "Write CONTENTS into FILE, creating its parent directory."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert contents))
  file)

(defun consult-zoxide-tests--stub-output (text &optional status)
  "Return a `consult-zoxide--call' stub emitting TEXT and returning STATUS."
  (lambda (destination &rest _args)
    (when (eq destination t) (insert text))
    (or status 0)))

(describe "consult-zoxide--query"
  (it "parses score and path out of each line, most frecent first"
    (spy-on 'consult-zoxide--call
            :and-call-fake
            (consult-zoxide-tests--stub-output
             "1056.0 /home/u/one\n  12.5 /home/u/two\n   0.2 /home/u/three\n"))
    (expect (consult-zoxide--query)
            :to-equal '(("/home/u/one" . 1056.0)
                        ("/home/u/two" . 12.5)
                        ("/home/u/three" . 0.2))))

  (it "keeps paths containing spaces intact"
    (spy-on 'consult-zoxide--call
            :and-call-fake
            (consult-zoxide-tests--stub-output "  3.0 /home/u/a dir/sub\n"))
    (expect (car (consult-zoxide--query)) :to-equal '("/home/u/a dir/sub" . 3.0)))

  (it "returns nothing for empty output"
    (spy-on 'consult-zoxide--call
            :and-call-fake (consult-zoxide-tests--stub-output ""))
    (expect (consult-zoxide--query) :to-be nil))

  (it "treats exit 1 as an empty result rather than a failure"
    ;; zoxide exits non-zero when a query matches nothing
    (spy-on 'consult-zoxide--call
            :and-call-fake (consult-zoxide-tests--stub-output "" 1))
    (expect (consult-zoxide--query "nomatch") :to-be nil))

  (it "errors on any other non-zero exit"
    (spy-on 'consult-zoxide--call
            :and-call-fake (consult-zoxide-tests--stub-output "boom" 2))
    (expect (consult-zoxide--query) :to-throw 'error))

  (it "asks for unavailable directories only when told to"
    (spy-on 'consult-zoxide--call
            :and-call-fake (consult-zoxide-tests--stub-output ""))
    (consult-zoxide--query)
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal '(t "query" "--list" "--score"))
    (consult-zoxide--query nil t)
    (expect (spy-calls-args-for 'consult-zoxide--call 1)
            :to-equal '(t "query" "--list" "--score" "--all")))

  (it "passes a query through as a single argument, never through a shell"
    (spy-on 'consult-zoxide--call
            :and-call-fake (consult-zoxide-tests--stub-output ""))
    (consult-zoxide--query "it's got quotes")
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal '(t "query" "--list" "--score" "it's got quotes"))))

(describe "consult-zoxide-directories"
  (before-each
    (spy-on 'consult-zoxide--call
            :and-call-fake
            (consult-zoxide-tests--stub-output
             " 9.0 /home/u/one\n 1.0 /home/u/two\n")))

  (it "returns bare paths in frecency order, for other completion sources"
    (expect (consult-zoxide-directories)
            :to-equal '("/home/u/one" "/home/u/two")))

  (it "takes no arguments, as an items function is called"
    (expect (funcall #'consult-zoxide-directories) :to-have-same-items-as
            '("/home/u/one" "/home/u/two")))

  (it "passes a query and the dead flag through"
    (consult-zoxide-directories "q" t)
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal '(t "query" "--list" "--score" "--all" "q"))))

(describe "consult-zoxide--git-root"
  :var (tmp)

  (before-each
    (setq consult-zoxide-tests--tmp (make-temp-file "czox-git" t))
    (setq tmp consult-zoxide-tests--tmp))

  (after-each (delete-directory tmp t))

  (it "returns nil for a directory that is not a checkout"
    (expect (consult-zoxide--git-root (consult-zoxide-tests--dir "plain")) :to-be nil))

  (it "recognises a plain checkout by its .git directory"
    (let ((repo (consult-zoxide-tests--dir "repo")))
      (consult-zoxide-tests--dir "repo" ".git")
      (expect (consult-zoxide--git-root repo)
              :to-equal (cons 'plain (expand-file-name ".git" repo)))))

  (it "recognises a worktree by the gitdir its .git file names"
    (let ((main (consult-zoxide-tests--dir "main"))
          (wt (consult-zoxide-tests--dir "wt")))
      (consult-zoxide-tests--write
       (expand-file-name ".git" wt)
       (format "gitdir: %s/.git/worktrees/wt\n" main))
      (expect (consult-zoxide--git-root wt)
              :to-equal (cons 'worktree (expand-file-name ".git/worktrees/wt" main)))))

  (it "recognises a submodule and resolves its relative gitdir"
    ;; submodules name the gitdir relative to the submodule directory,
    ;; which is what silently broke this the first time round
    (let ((sub (consult-zoxide-tests--dir "super" "modules" "sub")))
      (consult-zoxide-tests--write
       (expand-file-name ".git" sub)
       "gitdir: ../../.git/modules/sub\n")
      (expect (consult-zoxide--git-root sub)
              :to-equal (cons 'submodule
                              (expand-file-name ".git/modules/sub"
                                                (expand-file-name "super" tmp))))))

  (it "returns nil when the .git file names nothing"
    (let ((dir (consult-zoxide-tests--dir "junk")))
      (consult-zoxide-tests--write (expand-file-name ".git" dir) "garbage\n")
      (expect (consult-zoxide--git-root dir) :to-be nil))))

(describe "consult-zoxide--branch"
  :var (tmp gitdir)

  (before-each
    (setq consult-zoxide-tests--tmp (make-temp-file "czox-head" t))
    (setq tmp consult-zoxide-tests--tmp)
    (setq gitdir (consult-zoxide-tests--dir "gitdir")))

  (after-each (delete-directory tmp t))

  (it "reads a symbolic HEAD"
    (consult-zoxide-tests--write (expand-file-name "HEAD" gitdir)
                                 "ref: refs/heads/main\n")
    (expect (consult-zoxide--branch gitdir) :to-equal "main"))

  (it "keeps slashes in a branch name"
    (consult-zoxide-tests--write (expand-file-name "HEAD" gitdir)
                                 "ref: refs/heads/fix/some-thing\n")
    (expect (consult-zoxide--branch gitdir) :to-equal "fix/some-thing"))

  (it "abbreviates a detached HEAD"
    (consult-zoxide-tests--write
     (expand-file-name "HEAD" gitdir)
     "3f7a1c9b2e4d5a6f8901234567890abcdef12345\n")
    (expect (consult-zoxide--branch gitdir) :to-equal "@3f7a1c9"))

  (it "returns nil when HEAD is missing"
    (expect (consult-zoxide--branch gitdir) :to-be nil)))

(describe "consult-zoxide--candidates"
  :var (tmp live gone)

  (before-each
    (setq consult-zoxide-tests--tmp (make-temp-file "czox-cand" t))
    (setq tmp consult-zoxide-tests--tmp)
    (setq live (consult-zoxide-tests--dir "live"))
    (setq gone (expand-file-name "gone" tmp))
    (spy-on 'consult-zoxide--call
            :and-call-fake
            (consult-zoxide-tests--stub-output
             (format "  9.0 %s\n  1.0 %s\n" live gone))))

  (after-each (delete-directory tmp t))

  (it "carries the score on every candidate"
    (expect (get-text-property 0 'consult-zoxide-score
                               (car (consult-zoxide--candidates)))
            :to-equal 9.0))

  (it "tags a vanished directory dead and leaves a live one untagged"
    (let ((cands (consult-zoxide--candidates)))
      (expect (get-text-property 0 'consult-zoxide-tags (nth 0 cands)) :to-be nil)
      (expect (get-text-property 0 'consult-zoxide-tags (nth 1 cands))
              :to-equal '(dead))))

  (it "strikes through a vanished directory"
    (expect (get-text-property 0 'face (nth 1 (consult-zoxide--candidates)))
            :to-equal 'consult-zoxide-dead))

  (it "leaves a live directory unfaced"
    (expect (get-text-property 0 'face (nth 0 (consult-zoxide--candidates)))
            :to-be nil))

  (it "tags a checkout root git and records its gitdir"
    (consult-zoxide-tests--dir "live" ".git")
    (let ((cand (car (consult-zoxide--candidates))))
      (expect (get-text-property 0 'consult-zoxide-tags cand) :to-equal '(git))
      (expect (get-text-property 0 'consult-zoxide-gitdir cand)
              :to-equal (expand-file-name ".git" live))))

  (it "tags a worktree both git and worktree"
    (consult-zoxide-tests--write (expand-file-name ".git" live)
                                 "gitdir: /elsewhere/.git/worktrees/live\n")
    (expect (get-text-property 0 'consult-zoxide-tags
                               (car (consult-zoxide--candidates)))
            :to-equal '(git worktree)))

  (it "never examines a vanished directory for git-ness"
    (expect (get-text-property 0 'consult-zoxide-gitdir
                               (nth 1 (consult-zoxide--candidates)))
            :to-be nil)))

(describe "consult-zoxide--annotation"
  :var (tmp repo)

  (before-each
    (setq consult-zoxide-tests--tmp (make-temp-file "czox-annot" t))
    (setq tmp consult-zoxide-tests--tmp)
    (setq repo (consult-zoxide-tests--dir "myrepo"))
    (consult-zoxide-tests--write
     (expand-file-name ".git/HEAD" repo) "ref: refs/heads/topic\n")
    (spy-on 'consult-zoxide--call
            :and-call-fake
            (consult-zoxide-tests--stub-output (format " 42.0 %s\n" repo))))

  (after-each (delete-directory tmp t))

  (it "shows the score"
    (expect (substring-no-properties
             (consult-zoxide--annotation (car (consult-zoxide--candidates))))
            :to-equal "topic    42.0"))

  (it "shows the branch when it differs from the directory name"
    (expect (consult-zoxide--annotation (car (consult-zoxide--candidates)))
            :to-match "topic"))

  (it "suppresses a branch that just repeats the directory name"
    ;; the worktree-per-ticket layout names the directory after its branch
    (consult-zoxide-tests--write
     (expand-file-name ".git/HEAD" repo) "ref: refs/heads/myrepo\n")
    (expect (substring-no-properties
             (consult-zoxide--annotation (car (consult-zoxide--candidates))))
            :to-equal "  42.0"))

  (it "omits the branch entirely when annotation is turned off"
    (let ((consult-zoxide-annotate-branch nil))
      (expect (substring-no-properties
               (consult-zoxide--annotation (car (consult-zoxide--candidates))))
              :to-equal "  42.0")))

  (it "reads HEAD once per prompt when memoizing"
    (let ((consult-zoxide--branch-cache (make-hash-table :test #'equal))
          (cand (car (consult-zoxide--candidates))))
      (spy-on 'consult-zoxide--branch :and-return-value "topic")
      (consult-zoxide--annotation cand)
      (consult-zoxide--annotation cand)
      (consult-zoxide--annotation cand)
      (expect (spy-calls-count 'consult-zoxide--branch) :to-equal 1)))

  (it "returns nothing for a string that is not one of its candidates"
    (expect (consult-zoxide--annotation "/plain/string") :to-be nil)))

(describe "consult-zoxide--narrow-predicate"
  :var (cand)

  (before-each
    (setq cand (propertize "/some/where" 'consult-zoxide-tags '(git worktree))))

  (it "keeps everything when nothing is narrowed"
    (let ((consult--narrow nil))
      (expect (consult-zoxide--narrow-predicate "/untagged") :to-be-truthy)))

  (it "keeps a candidate carrying the narrowed tag"
    (let ((consult--narrow ?g))
      (expect (consult-zoxide--narrow-predicate cand) :to-be-truthy)))

  (it "matches a candidate on any of its tags, not just the first"
    (let ((consult--narrow ?w))
      (expect (consult-zoxide--narrow-predicate cand) :to-be-truthy)))

  (it "drops a candidate without the narrowed tag"
    (let ((consult--narrow ?d))
      (expect (consult-zoxide--narrow-predicate cand) :to-be nil))))

(describe "consult-zoxide-read"
  :var (tmp)

  (before-each
    (setq consult-zoxide-tests--tmp (make-temp-file "czox-read" t))
    (setq tmp consult-zoxide-tests--tmp))

  (after-each (delete-directory tmp t))

  (it "skips the prompt when zoxide singles out one directory"
    (spy-on 'consult-zoxide--call
            :and-call-fake (consult-zoxide-tests--stub-output " 5.0 /home/u/only\n"))
    (spy-on 'consult--read)
    (expect (consult-zoxide-read "only") :to-equal "/home/u/only")
    (expect 'consult--read :not :to-have-been-called))

  (it "prompts when several directories match"
    (spy-on 'consult-zoxide--call
            :and-call-fake
            (consult-zoxide-tests--stub-output " 5.0 /home/u/a\n 4.0 /home/u/b\n"))
    (spy-on 'consult--read :and-call-fake (lambda (cands &rest _) (cadr cands)))
    (expect (consult-zoxide-read) :to-equal "/home/u/b"))

  (it "returns a bare string, free of candidate properties"
    (spy-on 'consult-zoxide--call
            :and-call-fake
            (consult-zoxide-tests--stub-output " 5.0 /home/u/a\n 4.0 /home/u/b\n"))
    (spy-on 'consult--read :and-call-fake (lambda (cands &rest _) (car cands)))
    (expect (text-properties-at 0 (consult-zoxide-read)) :to-be nil))

  (it "hands consult its own category and leaves the order alone"
    (spy-on 'consult-zoxide--call
            :and-call-fake
            (consult-zoxide-tests--stub-output " 5.0 /home/u/a\n 4.0 /home/u/b\n"))
    (spy-on 'consult--read :and-call-fake (lambda (cands &rest _) (car cands)))
    (consult-zoxide-read)
    (let ((opts (cdr (spy-calls-args-for 'consult--read 0))))
      (expect (plist-get opts :category) :to-be 'consult-zoxide-dir)
      (expect (plist-member opts :sort) :to-be-truthy)
      (expect (plist-get opts :sort) :to-be nil)
      (expect (plist-get opts :annotate) :to-be #'consult-zoxide--annotate)
      (expect (plist-get (plist-get opts :narrow) :keys)
              :to-equal '((?g . "git repo") (?w . "worktree") (?d . "dead")))))

  (it "signals when the database has nothing to offer"
    (spy-on 'consult-zoxide--call
            :and-call-fake (consult-zoxide-tests--stub-output ""))
    (expect (consult-zoxide-read) :to-throw 'user-error)))

(describe "consult-zoxide-remove"
  :var (tmp live)

  (before-each
    (setq consult-zoxide-tests--tmp (make-temp-file "czox-rm" t))
    (setq tmp consult-zoxide-tests--tmp)
    (setq live (consult-zoxide-tests--dir "live"))
    (spy-on 'consult-zoxide--call :and-return-value 0))

  (after-each (delete-directory tmp t))

  (it "removes a single vanished entry"
    (consult-zoxide-remove "/gone/away")
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal '(t "remove" "/gone/away")))

  (it "removes a single live directory, which is not the dangerous case"
    (consult-zoxide-remove live)
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal (list t "remove" live)))

  (it "batches several vanished entries into one call"
    ;; one process for the lot; zoxide takes many paths per invocation
    (consult-zoxide-remove '("/gone/a" "/gone/b" "/gone/c"))
    (expect (spy-calls-count 'consult-zoxide--call) :to-equal 1)
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal '(t "remove" "/gone/a" "/gone/b" "/gone/c")))

  (it "refuses a bulk removal containing a live directory"
    (expect (consult-zoxide-remove (list "/gone/a" live)) :to-throw 'user-error))

  (it "spawns nothing at all when it refuses"
    (ignore-errors (consult-zoxide-remove (list "/gone/a" live)))
    (expect 'consult-zoxide--call :not :to-have-been-called))

  (it "refuses even when every path is live"
    (expect (consult-zoxide-remove (list live live)) :to-throw 'user-error))

  (it "counts the live paths in the refusal"
    (let ((other (consult-zoxide-tests--dir "other")))
      (expect (condition-case err
                  (consult-zoxide-remove (list live other "/gone"))
                (user-error (error-message-string err)))
              :to-match "2 live directories")))

  (it "treats a remote path as live rather than reaching over the network"
    (expect (consult-zoxide-remove '("/ssh:host:/srv" "/gone/a"))
            :to-throw 'user-error))

  (it "accepts a one element list, which is how embark hands over a target"
    (consult-zoxide-remove '("/gone/a"))
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal '(t "remove" "/gone/a")))

  (it "strips candidate properties before handing paths to zoxide"
    (consult-zoxide-remove (list (propertize "/gone/a" 'consult-zoxide-score 1.0)))
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal '(t "remove" "/gone/a")))

  (it "signals when zoxide reports failure"
    (spy-on 'consult-zoxide--call :and-return-value 1)
    (expect (consult-zoxide-remove "/gone/a") :to-throw 'error))

  (it "signals when handed nothing"
    (expect (consult-zoxide-remove nil) :to-throw 'user-error)))

(describe "consult-zoxide-track"
  :var (tmp)

  (before-each
    (setq consult-zoxide-tests--tmp (make-temp-file "czox-track" t))
    (setq tmp consult-zoxide-tests--tmp)
    (spy-on 'consult-zoxide--call :and-return-value 0))

  (after-each (delete-directory tmp t))

  (it "records the directory of a file buffer"
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "file.el" tmp))
      (consult-zoxide-track)
      (setq buffer-file-name nil))
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal (list t "add" (file-name-as-directory tmp))))

  (it "records dired-directory in a dired buffer"
    (with-temp-buffer
      (dired-mode tmp)
      (consult-zoxide-track))
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal (list t "add" tmp)))

  (it "skips a buffer visiting nothing"
    (with-temp-buffer (consult-zoxide-track))
    (expect 'consult-zoxide--call :not :to-have-been-called))

  (it "skips an unreadable directory"
    (with-temp-buffer
      (setq buffer-file-name "/definitely/not/here/file.el")
      (consult-zoxide-track)
      (setq buffer-file-name nil))
    (expect 'consult-zoxide--call :not :to-have-been-called))

  (it "skips a remote buffer instead of shelling out over tramp"
    (with-temp-buffer
      (setq buffer-file-name "/ssh:host:/srv/file.el")
      (consult-zoxide-track)
      (setq buffer-file-name nil))
    (expect 'consult-zoxide--call :not :to-have-been-called)))

(describe "consult-zoxide-track-mode"
  (after-each (consult-zoxide-track-mode -1))

  (it "hooks dired on, and only dired"
    (consult-zoxide-track-mode 1)
    (expect (memq #'consult-zoxide-track dired-after-readin-hook) :to-be-truthy)
    (expect (memq #'consult-zoxide-track find-file-hook) :to-be nil))

  (it "unhooks dired off"
    (consult-zoxide-track-mode 1)
    (consult-zoxide-track-mode -1)
    (expect (memq #'consult-zoxide-track dired-after-readin-hook) :to-be nil)))

;;; consult-zoxide-tests.el ends here
