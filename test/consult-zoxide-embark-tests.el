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

  (it "shadows the parent's on-disk deletion keys"
    ;; delete-file/delete-directory have no business one key from "forget"
    (consult-zoxide-embark-register)
    (expect (keymap-lookup embark-file-map "d") :to-be #'delete-file)
    (expect (keymap-lookup embark-file-map "D") :to-be #'delete-directory)
    (expect (keymap-lookup consult-zoxide-embark-map "d") :to-be nil)
    (expect (keymap-lookup consult-zoxide-embark-map "D") :to-be nil))

  (it "registers removal as a multi-target action"
    ;; so act-all hands zoxide one batched call instead of a process each
    (setq embark-multitarget-actions nil)
    (consult-zoxide-embark-register)
    (expect (memq #'consult-zoxide-remove embark-multitarget-actions)
            :to-be-truthy))

  (it "asks for a session restart after removal"
    (setq embark-post-action-hooks nil)
    (consult-zoxide-embark-register)
    (expect (alist-get 'consult-zoxide-remove embark-post-action-hooks)
            :to-equal '(embark--restart)))

  (it "keeps the session alive across a removal"
    (setq embark-quit-after-action t)
    (consult-zoxide-embark-register)
    (expect (alist-get 'consult-zoxide-remove embark-quit-after-action)
            :to-be nil)
    (expect (alist-get t embark-quit-after-action) :to-be t))

  (it "preserves a nil global default when widening it into an alist"
    (setq embark-quit-after-action nil)
    (consult-zoxide-embark-register)
    (expect (alist-get t embark-quit-after-action) :to-be nil))

  (it "leaves an existing quit alist untouched apart from its own entry"
    (setq embark-quit-after-action '((some-other-action . t) (t . nil)))
    (consult-zoxide-embark-register)
    (expect (alist-get 'some-other-action embark-quit-after-action) :to-be t)
    (expect (alist-get t embark-quit-after-action) :to-be nil))

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

(describe "the Embark autoload hook"
  (it "has already registered, Embark being loaded"
    ;; the ;;;###autoload (with-eval-after-load 'embark ...) form fires on
    ;; require when Embark is present, so no manual setup is needed
    (expect (alist-get 'consult-zoxide-dir embark-keymap-alist)
            :to-be 'consult-zoxide-embark-map)))

(describe "embark-act-all against the removal guard"
  :var (tmp live)

  (before-each
    (setq tmp (make-temp-file "czox-embark" t))
    (setq live (expand-file-name "live" tmp))
    (make-directory live t))

  (after-each (delete-directory tmp t))

  (it "takes a whole batch of vanished entries in one call"
    ;; embark hands multi-target actions the list of candidates
    (spy-on 'consult-zoxide--call :and-return-value 0)
    (consult-zoxide-remove (list "/gone/a" "/gone/b"))
    (expect (spy-calls-count 'consult-zoxide--call) :to-equal 1))

  (it "still refuses when a live directory is among them"
    (spy-on 'consult-zoxide--call :and-return-value 0)
    (expect (consult-zoxide-remove (list "/gone/a" live)) :to-throw 'user-error)
    (expect 'consult-zoxide--call :not :to-have-been-called)))

;;; consult-zoxide-embark-tests.el ends here
