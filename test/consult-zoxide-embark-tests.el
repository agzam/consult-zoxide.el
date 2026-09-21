;;; consult-zoxide-embark-tests.el --- Tests for the Embark integration -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Every spec here restores the Embark variables the registration mutates,
;;  so the suite can re-run registration from a known starting point.
;;
;;; Code:

(require 'buttercup)
(require 'embark)
(require 'consult-zoxide)
(require 'consult-zoxide-embark)

;; Registration is opt-in, so the specs below that read Embark's variables
;; have to ask for it, the way a user's config does.
(consult-zoxide-embark-register)

(describe "consult-zoxide-embark-register"
  :var (keymap-alist multitarget post-hooks quit-after parent)

  (before-each
    (setq keymap-alist (copy-tree embark-keymap-alist)
          multitarget (copy-sequence embark-multitarget-actions)
          post-hooks (copy-tree embark-post-action-hooks)
          quit-after (if (consp embark-quit-after-action)
                         (copy-tree embark-quit-after-action)
                       embark-quit-after-action)
          parent (keymap-parent consult-zoxide-embark-map)))

  (after-each
    (setq embark-keymap-alist keymap-alist
          embark-multitarget-actions multitarget
          embark-post-action-hooks post-hooks
          embark-quit-after-action quit-after)
    (set-keymap-parent consult-zoxide-embark-map parent))

  (it "claims the consult-zoxide-dir category"
    (setq embark-keymap-alist nil)
    (consult-zoxide-embark-register)
    (expect (alist-get 'consult-zoxide-dir embark-keymap-alist)
            :to-be 'consult-zoxide-embark-map))

  (it "inherits from the file map, so every file action still applies"
    (consult-zoxide-embark-register)
    (expect (keymap-parent consult-zoxide-embark-map) :to-be embark-file-map)
    (expect (keymap-lookup consult-zoxide-embark-map "RET") :to-be #'find-file))

  (it "puts removal on the key Embark already uses for forgetting history"
    (expect (keymap-lookup consult-zoxide-embark-map "\\")
            :to-be #'consult-zoxide-remove))

  (it "sends both deletion keys at the directory, not at a file"
    ;; every candidate is a directory, so the inherited delete-file on `d'
    ;; could only ever error
    (consult-zoxide-embark-register)
    (expect (keymap-lookup embark-file-map "d") :to-be #'delete-file)
    (expect (keymap-lookup consult-zoxide-embark-map "d")
            :to-be #'delete-directory)
    (expect (keymap-lookup consult-zoxide-embark-map "D")
            :to-be #'delete-directory))

  (it "leaves the confirmation in front of them to Embark"
    ;; no prompt of our own: embark-pre-action-hooks already has one
    (expect (alist-get 'delete-directory embark-pre-action-hooks)
            :to-contain #'embark--confirm)
    (expect (alist-get 'delete-file embark-pre-action-hooks)
            :to-contain #'embark--confirm))

  (it "registers removal as a multi-target action"
    ;; so act-all hands zoxide one batched call instead of a process each
    (setq embark-multitarget-actions nil)
    (consult-zoxide-embark-register)
    (expect (memq #'consult-zoxide-remove embark-multitarget-actions)
            :to-be-truthy))

  (it "asks for a session restart after removal"
    (setq embark-post-action-hooks nil)
    (consult-zoxide-embark-register)
    ;; not embark--restart itself: that one no-ops for a multi-target action
    (expect (alist-get 'consult-zoxide-remove embark-post-action-hooks)
            :to-equal '(consult-zoxide-embark--restart)))

  (it "leaves embark-quit-after-action to the user"
    ;; whether the prompt survives a removal is not ours to decide, and
    ;; touching it lost to whichever config setopt ran last anyway
    (dolist (setting (list t nil '((some-other-action . t) (t . nil))))
      (setq embark-quit-after-action setting)
      (consult-zoxide-embark-register)
      (expect embark-quit-after-action :to-equal setting)))

  (it "is idempotent"
    (setq embark-keymap-alist nil
          embark-multitarget-actions nil)
    (consult-zoxide-embark-register)
    (consult-zoxide-embark-register)
    (expect (seq-count (lambda (entry) (eq (car entry) 'consult-zoxide-dir))
                       embark-keymap-alist)
            :to-equal 1)
    (expect (seq-count (lambda (action) (eq action #'consult-zoxide-remove))
                       embark-multitarget-actions)
            :to-equal 1)))

(describe "consult-zoxide-embark--restart"
  (it "reaches the minibuffer from whatever buffer the hook runs in"
    ;; the whole point: embark--act runs a multi-target action's post hooks
    ;; selected on the target window, where a bare embark--restart no-ops
    (let (minibuffer-seen)
      (spy-on 'active-minibuffer-window :and-return-value (minibuffer-window))
      (spy-on 'embark--restart :and-call-fake
              (lambda (&rest _) (setq minibuffer-seen (minibufferp))))
      (with-temp-buffer
        (expect (minibufferp) :to-be nil)
        (consult-zoxide-embark--restart))
      (expect minibuffer-seen :to-be t)))

  (it "does nothing when no prompt is open"
    (spy-on 'active-minibuffer-window :and-return-value nil)
    (spy-on 'embark--restart)
    (consult-zoxide-embark--restart)
    (expect 'embark--restart :not :to-have-been-called)))

(describe "loading the file"
  (it "registers nothing of its own accord"
    ;; installing a package must not reach into Embark; only an explicit
    ;; `consult-zoxide-embark-register' from the user's config may
    (let ((embark-keymap-alist nil)
          (embark-multitarget-actions nil)
          (embark-post-action-hooks nil))
      (load (locate-library "consult-zoxide-embark") nil t)
      (expect embark-keymap-alist :to-be nil)
      (expect embark-multitarget-actions :to-be nil)
      (expect embark-post-action-hooks :to-be nil))))

(describe "a zoxide row in a consult-dir prompt"
  (before-each
    (spy-on 'consult-zoxide--call
            :and-call-fake
            (lambda (destination &rest _)
              (when (eq destination t) (insert " 9.0 /home/u/one\n"))
              0)))

  (it "reaches the zoxide keymap, not the plain file one"
    ;; the source has to report itself as `file' to consult-dir, so without
    ;; the candidate's own datum embark refines the target to a file and the
    ;; removal key is embark-recentf-remove instead
    (let* ((candidate (concat (car (consult-zoxide--source-items))
                              ;; consult marks which source a candidate came
                              ;; from with an invisible character appended to
                              ;; it, which is why the refinement below has to
                              ;; hand back the datum and not the target string
                              (string #x200000)))
           (target (embark--refine-multi-category 'multi-category candidate))
           (keymap (symbol-value (alist-get (car target) embark-keymap-alist))))
      (expect target :to-equal '(consult-zoxide-dir . "/home/u/one"))
      (expect keymap :to-be consult-zoxide-embark-map)
      (expect (keymap-lookup keymap "\\") :to-be #'consult-zoxide-remove))))

(describe "embark-act-all against the removal guard"
  :var (tmp live other)

  (before-each
    (setq tmp (make-temp-file "czox-embark" t))
    (setq live (expand-file-name "live" tmp))
    (setq other (expand-file-name "other" tmp))
    (make-directory live t)
    (make-directory other t)
    (spy-on 'consult-zoxide--call :and-return-value 0))

  (after-each (delete-directory tmp t))

  (it "takes a whole batch of vanished entries in one call"
    ;; embark hands multi-target actions the list of candidates
    (consult-zoxide-remove (list "/gone/a" "/gone/b"))
    (expect (spy-calls-count 'consult-zoxide--call) :to-equal 1))

  (it "removes a selected batch of live directories, once confirmed"
    ;; the whole reported bug: act-all hands the multi-target action every
    ;; selected candidate at once, and the guard used to reject the lot
    (spy-on 'y-or-n-p :and-return-value t)
    (embark--act #'consult-zoxide-remove
                 (list :type 'consult-zoxide-dir
                       :candidates (list live other)))
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal (list t "remove" live other)))

  (it "leaves the batch alone when the question is declined"
    (spy-on 'y-or-n-p :and-return-value nil)
    (expect (embark--act #'consult-zoxide-remove
                         (list :type 'consult-zoxide-dir
                               :candidates (list live other)))
            :to-throw 'user-error)
    (expect 'consult-zoxide--call :not :to-have-been-called))

  (it "asks nothing of a single target, embark wrapping it in a list"
    ;; the `\' key on one row: embark--act fills :candidates itself
    (spy-on 'y-or-n-p :and-return-value nil)
    (embark--act #'consult-zoxide-remove
                 (list :type 'consult-zoxide-dir :target live))
    (expect 'y-or-n-p :not :to-have-been-called)
    (expect (spy-calls-args-for 'consult-zoxide--call 0)
            :to-equal (list t "remove" live))))

;;; consult-zoxide-embark-tests.el ends here
