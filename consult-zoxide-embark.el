;;; consult-zoxide-embark.el --- Embark integration for consult-zoxide -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Assisted-by: Claude:claude-opus-4-5
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Optional Embark integration, activated by calling
;; `consult-zoxide-embark-register':
;;
;;   (with-eval-after-load 'embark
;;     (consult-zoxide-embark-register))
;;
;; That function is autoloaded, so the line above needs no `require',
;; and nothing here runs until you put it there.  Embark is not a
;; dependency.
;;
;; It gives the `consult-zoxide-dir' category a keymap inheriting from
;; `embark-file-map', so every file action applies, and adds removal on
;; the \ key - the one Embark already uses for dropping a recentf entry.
;;
;; The d key is rebound to `delete-directory', the inherited
;; `delete-file' having nothing to act on in a category whose every
;; candidate is a directory.  Both it and D delete off disk after the
;; confirmation prompt Embark's own `embark-pre-action-hooks' puts in
;; front of them.
;;
;; Removal is registered as a multi-target action, so acting on a whole
;; narrowed set hands zoxide one batched call rather than spawning a
;; process per entry.  That choice is also why removal cannot simply
;; hang `embark--restart' off `embark-post-action-hooks' the way Embark's
;; own single-target `delete-file' does; see
;; `consult-zoxide-embark--restart'.
;;
;; `embark-quit-after-action' is left alone.  Whether the prompt survives
;; a removal is the user's setting to make, and either answer works: the
;; prompt either closes or comes back without the rows just removed.

;;; Code:

(require 'consult-zoxide)

(declare-function embark--restart "embark" (&rest _))

;; Embark variables this file registers into.  Declared so it byte-compiles
;; without Embark present.
(defvar embark-file-map)
(defvar embark-keymap-alist)
(defvar embark-multitarget-actions)
(defvar embark-post-action-hooks)

(defvar-keymap consult-zoxide-embark-map
  :doc "Embark actions for zoxide directory entries."
  "\\" #'consult-zoxide-remove
  "d" #'delete-directory)

(defun consult-zoxide-embark--restart (&rest _)
  "Reopen the prompt, so the rows just removed are gone from it."
  ;; `embark--act' runs a multi-target action's post-action hooks inside
  ;; `with-selected-window' on the target window, where `embark--restart'
  ;; finds no minibuffer current and does nothing.
  (when-let* ((window (active-minibuffer-window)))
    (with-current-buffer (window-buffer window)
      (embark--restart))))

;;;###autoload
(defun consult-zoxide-embark-register ()
  "Register the `consult-zoxide-dir' category with Embark.
Nothing registers itself; call this after `embark' loads."
  (set-keymap-parent consult-zoxide-embark-map embark-file-map)
  (add-to-list 'embark-keymap-alist
               '(consult-zoxide-dir . consult-zoxide-embark-map))
  (add-to-list 'embark-multitarget-actions #'consult-zoxide-remove)
  ;; `embark-act-all' suppresses the per-candidate restart and fires this
  ;; once at the end, so one refresh follows a whole narrowed set
  (setf (alist-get 'consult-zoxide-remove embark-post-action-hooks)
        '(consult-zoxide-embark--restart)))

(provide 'consult-zoxide-embark)

;; Local Variables:
;; package-lint-main-file: "consult-zoxide.el"
;; End:
;;; consult-zoxide-embark.el ends here
