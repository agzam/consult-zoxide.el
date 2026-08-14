;;; consult-zoxide-embark.el --- Embark integration for consult-zoxide -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Optional Embark integration.  An autoloaded hook activates it as soon
;; as Embark loads, so Embark stays a non-runtime dependency and users
;; without it are unaffected.
;;
;; It gives the `consult-zoxide-dir' category a keymap inheriting from
;; `embark-file-map', so every file action applies, and adds removal on
;; `\\' - the key Embark already uses for dropping a recentf entry.
;;
;; `d' and `D' are shadowed to nil.  They delete a directory off disk,
;; and that has no business sitting one keystroke away from forgetting
;; its history entry; Dired is where directories get deleted.
;;
;; Removal is registered as a multi-target action, so acting on a whole
;; narrowed set hands zoxide one batched call rather than spawning a
;; process per entry.

;;; Code:

(require 'consult-zoxide)

(declare-function embark--restart "embark" (&rest _))

;; Embark variables this file registers into.  Declared so it byte-compiles
;; without Embark present.
(defvar embark-file-map)
(defvar embark-keymap-alist)
(defvar embark-multitarget-actions)
(defvar embark-post-action-hooks)
(defvar embark-quit-after-action)

(defvar-keymap consult-zoxide-embark-map
  :doc "Embark actions for zoxide directory entries.
`consult-zoxide-embark-register' makes `embark-file-map' its parent."
  "\\" #'consult-zoxide-remove
  "d" nil
  "D" nil)

;;;###autoload
(defun consult-zoxide-embark-register ()
  "Register the `consult-zoxide-dir' category with Embark."
  (set-keymap-parent consult-zoxide-embark-map embark-file-map)
  (add-to-list 'embark-keymap-alist
               '(consult-zoxide-dir . consult-zoxide-embark-map))
  (add-to-list 'embark-multitarget-actions #'consult-zoxide-remove)
  ;; `embark-act-all' suppresses the per-candidate restart and fires this
  ;; once at the end, so the prompt comes back without the removed rows
  (setf (alist-get 'consult-zoxide-remove embark-post-action-hooks)
        '(embark--restart))
  ;; ...but only for an action that leaves the session standing.  Widening
  ;; a boolean setting into an alist keeps whatever it was as the default.
  (unless (consp embark-quit-after-action)
    (setq embark-quit-after-action (list (cons t embark-quit-after-action))))
  (setf (alist-get 'consult-zoxide-remove embark-quit-after-action) nil))

;; Activate as soon as Embark is available.  The cookie copies this form
;; into the generated autoloads, so the integration works off the bat for
;; anyone who has Embark, with no manual `require'.  Going through the
;; autoloaded register function rather than `(require 'consult-zoxide-embark)'
;; avoids a load recursion when this file is itself loaded with Embark
;; already present.
;;;###autoload
(with-eval-after-load 'embark
  (consult-zoxide-embark-register))

(provide 'consult-zoxide-embark)

;; Local Variables:
;; package-lint-main-file: "consult-zoxide.el"
;; End:
;;; consult-zoxide-embark.el ends here
