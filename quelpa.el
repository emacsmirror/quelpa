;;; quelpa.el --- Your personal ELPA with packages built directly from source

;; Copyright 2014, Steckerhalter

;; Author: steckerhalter
;; URL: https://github.com/quelpa/quelpa
;; Version: 0.0.1
;; Package-Requires: ((package-build "0"))
;; Keywords: package management build source elpa

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Your personal local Emacs Lisp Package Archive (ELPA) with packages
;; built on-the-fly directly from source.

;; See the README.org for more info:
;; https://github.com/steckerhalter/quelpa/README.org

;;; Requirements:

;; Emacs 24.

;;; Code:

(require 'package-build)
(require 'cl-lib)

;; --- variables -------------------------------------------------------------

(defvar quelpa-dir (expand-file-name (concat user-emacs-directory "quelpa"))
  "Where quelpa builds and stores packages.")

(defvar quelpa-build-dir (concat quelpa-dir "/build")
  "Where quelpa builds packages.")

(defvar quelpa-packages-dir (concat quelpa-dir "/packages")
  "The quelpa package archive.")

(defvar quelpa-melpa-dir (concat quelpa-dir "/melpa")
  "Where melpa is checked out (to get the recipes).")

(defvar quelpa-initialized-p nil
  "Non-nil when quelpa has been initialized.")

(defvar quelpa-legacy-p (version< emacs-version "24.3.50")
  "Non-nil if Emacs version is below 24.3.50.")

;; --- compatibility for legacy `package.el' in Emacs 24.3  -------------------

(defun quelpa-setup-package-structs ()
  "Setup the structs `package-desc' and `package--ac-desc'.
We want to keep the compat cruft at a minimal level so we just
add these structs if they are not available."
  (unless (functionp 'package-desc-p)
    (cl-defstruct
        (package-desc
         (:constructor
          ;; convert legacy package desc into PACKAGE-DESC
          package-desc-from-legacy
          (pkg-info kind
                    &aux
                    (name (intern (aref pkg-info 0)))
                    (version (version-to-list (aref pkg-info 3)))
                    (summary (if (string= (aref pkg-info 2) "")
                                 "No description available."
                               (aref pkg-info 2)))
                    (reqs  (aref pkg-info 1))
                    (kind kind))))
      name
      version
      (summary "No description available.")
      reqs
      kind
      archive
      dir
      extras
      signed)))

;; --- archive-contents building ---------------------------------------------

(defun quelpa-package-type (file)
  "Determine the package type of FILE.
Return `tar' for tarball packages, `single' for single file
packages, or nil, if FILE is not a package."
  (let ((ext (file-name-extension file)))
    (cond
     ((string= ext "tar") 'tar)
     ((string= ext "el") 'single)
     (:else nil))))

(defun quelpa-create-index-entry (file)
  "Create a package index entry for the package at FILE.
Return a package index entry."
  (let ((pkg-desc (quelpa-get-package-desc file)))
    (when pkg-desc
      (let* ((file-type (package-desc-kind pkg-desc))
             (pkg-name (package-desc-name pkg-desc))
             (requires (package-desc-reqs pkg-desc))
             (desc (package-desc-summary pkg-desc))
             (split-version (package-desc-version pkg-desc))
             (extras (package-desc-extras pkg-desc)))
        (cons pkg-name
	      (if quelpa-legacy-p
		  (vector split-version requires desc file-type extras)
		(package-make-ac-desc split-version requires desc file-type extras)))))))

(defun quelpa-get-package-desc (file)
  "Extract and return the PACKAGE-DESC struct from FILE.
On error return nil."
  (let* ((kind (quelpa-package-type file))
         (desc (with-demoted-errors "Error getting PACKAGE-DESC: %s"
                 (with-temp-buffer
                   (insert-file-contents-literally file)
                   (pcase kind
                     (`single (package-buffer-info))
                     (`tar (tar-mode)
                           (if quelpa-legacy-p (package-tar-file-info file)
                             (with-no-warnings (package-tar-file-info)))))))))
    (pcase desc
      ((pred package-desc-p) desc)
      ((pred vectorp) (package-desc-from-legacy desc kind)))))

(defun quelpa-create-index (directory)
  "Generate a package index for DIRECTORY."
  (let* ((package-files (delq nil (mapcar (lambda (f) (when (quelpa-package-type f) f))
                                          (directory-files directory t))))
         (entries (delq nil (mapcar 'quelpa-create-index-entry package-files))))
    (append (list 1) entries)))

(defun quelpa-create-index-string (directory)
  "Generate a package index for DIRECTORY as string."
  (let ((print-level nil)
        (print-length nil))
    (concat "\n" (prin1-to-string (quelpa-create-index directory)))))

(defun quelpa-build-archive-contents ()
  (with-temp-file (concat quelpa-packages-dir "/archive-contents")
    (insert (quelpa-create-index-string quelpa-packages-dir))))

;; --- package building ------------------------------------------------------

(defun quelpa-archive-file-name (archive-entry)
  "Return the path of the file in which the package for ARCHIVE-ENTRY is stored."
  (let* ((name (car archive-entry))
         (pkg-info (cdr archive-entry))
         (version (package-version-join (aref pkg-info 0)))
         (flavour (aref pkg-info 3)))
    (expand-file-name
     (format "%s-%s.%s" name version (if (eq flavour 'single) "el" "tar"))
     quelpa-packages-dir)))

(defun quelpa-build-package (rcp)
  "Build a package from the given recipe RCP.
Uses the `package-build' library to get the source code and build
an elpa compatible package in `quelpa-build-dir' storing it in
`quelpa-packages-dir'.
Return the path to the created file."
  (ignore-errors (delete-directory quelpa-build-dir t))
  (let* ((name (car rcp))
         (version (package-build-checkout name (cdr rcp) quelpa-build-dir)))
    (quelpa-archive-file-name
     (package-build-package (symbol-name name)
                            version
                            (pb/config-file-list rcp)
                            quelpa-build-dir
                            quelpa-packages-dir))))

;; --- helpers ---------------------------------------------------------------

(defun quelpa-refresh-contents ()
  "Refresh the elpa package archive cache."
  (let ((archive `("quelpa" . ,quelpa-packages-dir)))
    (condition-case-unless-debug nil
        (package--download-one-archive archive "archive-contents")
      (error (message "Failed to download `%s' archive."
                      (car archive))))
    (package-read-archive-contents (car archive))))

(defun quelpa-checkout-melpa ()
  "Fetch or update the melpa source code from Github."
  (pb/checkout-git 'melpa
                   '(:url "git://github.com/milkypostman/melpa.git")
                   quelpa-melpa-dir))

(defun quelpa-get-melpa-recipe (name)
  "Read recipe with NAME for melpa git checkout.
Return the recipe if it exists, otherwise nil."
  (let* ((recipes-path (concat quelpa-melpa-dir "/recipes"))
         (files (directory-files recipes-path nil "^[^\.]+"))
         (file (assoc-string name files)))
    (when file
      (with-temp-buffer
        (insert-file-contents-literally (concat recipes-path "/" file))
        (read (buffer-string))))))

(defun quelpa-init ()
  "Setup what we need for quelpa if not done."
  (unless quelpa-initialized-p
    (quelpa-setup-package-structs)
    (add-to-list
     'package-archives
     `("quelpa" . ,quelpa-packages-dir))
    (unless (file-exists-p quelpa-packages-dir)
      (make-directory quelpa-packages-dir t))
    (quelpa-checkout-melpa)
    (setq quelpa-initialized-p t)))

(defun quelpa-arg-pkg (arg)
  (pcase arg
    ((pred listp) (car arg))
    ((pred symbolp) arg)))

(defun quelpa-arg-rcp (arg)
  (pcase arg
    ((pred listp) arg)
    ((pred symbolp)
     (or (quelpa-get-melpa-recipe arg)
         (error "Quelpa cannot find a package named %s" arg)))))

(defun quelpa-package-install (arg)
  "Build and install package from ARG.
If the package has dependencies recursively call this function to
install them."
  (let ((pkg (quelpa-arg-pkg arg)))
    (unless (package-installed-p pkg)
      (let* ((rcp (quelpa-arg-rcp arg))
             (file (quelpa-build-package rcp))
             (pkg-desc (quelpa-get-package-desc file))
             (requires (package-desc-reqs pkg-desc)))
        (when requires
          (mapc (lambda (req)
                  (unless (equal 'emacs (car req))
                    (quelpa-package-install (car req))))
                requires))
        (quelpa-build-archive-contents)
        (quelpa-refresh-contents)
        (package-install pkg)))))

;; --- public interface ------------------------------------------------------

;;;###autoload
(defun quelpa (arg)
  "Build and install a package with quelpa.
ARG can be a package name (symbol) or a melpa recipe (lins)."
  (quelpa-init)
  (quelpa-package-install arg))

(provide 'quelpa)

;;; quelpa.el ends here
