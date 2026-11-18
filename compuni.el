;;; compuni.el --- Ephemeral company-mode Unicode and Emoji insertion -*- lexical-binding: t; -*-

;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (company "0.9.13"))
;; Keywords: convenience, unicode, emoji, completion

;;; Commentary:

;; compuni provides fast, on-demand Unicode character and Emoji insertion
;; using `company-mode' purely as an ephemeral UI.  Multi-word substring
;; narrowing works directly in the buffer (including spaces), and
;; `company-mode' is restored to its prior state as soon as completion
;; finishes or is cancelled.

;;; Code:

(require 'cl-lib)
(require 'company)
(require 'thingatpt)

;; Silence byte-compiler for Emacs 29+ internal emoji symbols loaded lazily.
(defvar emoji--names)
(declare-function emoji--init "emoji")

;;; Customization

(defgroup compuni nil
  "Ephemeral company-mode completion for Unicode characters and Emojis."
  :group 'convenience
  :prefix "compuni-")

(defcustom compuni-max-candidates 50
  "Maximum number of candidates returned per query."
  :type 'natnum
  :group 'compuni)

(defcustom compuni-annotation-format "  %s"
  "Format string used to display the character next to its name in the popup."
  :type 'string
  :group 'compuni)

(defcustom compuni-exclude-cjk-ideographs t
  "When non-nil, exclude algorithmically named CJK/Hangul/Tangut ideographs.
This reduces the Unicode dataset from ~145,000 to ~35,000 entries while
keeping symbols, math/Greek letters, arrows, punctuation, and scripts."
  :type 'boolean
  :group 'compuni
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'compuni-clear-cache)
           (compuni-clear-cache))))

;;; Data Providers (Lazy-Loaded Hidden Buffers)

(defconst compuni--unicode-buffer-name " *compuni-unicode*"
  "Name of the hidden buffer caching Unicode entries.")

(defconst compuni--emoji-buffer-name " *compuni-emoji*"
  "Name of the hidden buffer caching Emoji entries.")

(defun compuni-clear-cache ()
  "Clear cached Unicode and Emoji buffers so they rebuild on next use."
  (interactive)
  (dolist (name (list compuni--unicode-buffer-name compuni--emoji-buffer-name))
    (when-let* ((buf (get-buffer name)))
      (kill-buffer buf))))

(defun compuni--make-candidate (name char)
  "Create a propertized candidate string from downcased NAME and CHAR."
  (propertize (downcase name) 'compuni-char char))

(defun compuni--excluded-unicode-name-p (name)
  "Return non-nil if Unicode NAME should be excluded from the cache."
  (and compuni-exclude-cjk-ideographs
       (or (string-prefix-p "CJK UNIFIED IDEOGRAPH-" name)
           (string-prefix-p "CJK COMPATIBILITY IDEOGRAPH-" name)
           (string-prefix-p "HANGUL SYLLABLE " name)
           (string-prefix-p "TANGUT IDEOGRAPH-" name))))

(defun compuni--get-or-build-buffer (buffer-name populate-fn)
  "Return cached BUFFER-NAME, populating it via POPULATE-FN if needed."
  (let ((buf (get-buffer buffer-name)))
    (if (and (buffer-live-p buf) (> (buffer-size buf) 0))
        buf
      (setq buf (get-buffer-create buffer-name))
      (with-current-buffer buf
        (let ((inhibit-modification-hooks t))
          (setq buffer-undo-list t)
          (erase-buffer)
          (funcall populate-fn)))
      buf)))

(defun compuni--get-unicode-buffer ()
  "Return the hidden buffer containing Unicode entries."
  (compuni--get-or-build-buffer
   compuni--unicode-buffer-name
   (lambda ()
     (maphash
      (lambda (name codepoint)
        (when (and (stringp name)
                   (characterp codepoint)
                   (not (compuni--excluded-unicode-name-p name)))
          (insert (downcase name) "\t" (char-to-string codepoint) "\n")))
      (ucs-names)))))

(defun compuni--get-emoji-buffer ()
  "Return the hidden buffer containing Emoji entries from Emacs's `emoji.el'."
  (compuni--get-or-build-buffer
   compuni--emoji-buffer-name
   (lambda ()
     (require 'emoji)
     (when (and (fboundp 'emoji--init)
                (or (not (boundp 'emoji--names))
                    (not (hash-table-p emoji--names))
                    (zerop (hash-table-count emoji--names))))
       (emoji--init))
     (unless (and (boundp 'emoji--names)
                  (hash-table-p emoji--names)
                  (> (hash-table-count emoji--names) 0))
       (user-error "Compuni: Emacs native emoji table `emoji--names' is unavailable"))
     (maphash
      (lambda (glyph name)
        (when (and (stringp glyph) (stringp name))
          (insert (downcase name) "\t" glyph "\n")))
      emoji--names))))

(defun compuni--candidate-char (candidate)
  "Extract the character string attached to CANDIDATE."
  (or (get-text-property 0 'compuni-char candidate)
      (when (and compuni--active-session
                 (buffer-live-p (compuni--session-buffer compuni--active-session)))
        (with-current-buffer (compuni--session-buffer compuni--active-session)
          (save-excursion
            (let ((case-fold-search nil)
                  (needle (concat (downcase candidate) "\t")))
              (goto-char (point-min))
              (when (or (and (looking-at-p (regexp-quote needle))
                             (goto-char (+ (point) (length needle))))
                        (search-forward (concat "\n" needle) nil t))
                (buffer-substring-no-properties (point) (line-end-position)))))))))

;;; Search Engine (C-Level Buffer Scan + Incremental Narrowing)

(defun compuni--filter-buffer (query buffer &optional max-results)
  "Search BUFFER for lines matching all space-separated words in QUERY.
Returns a cons cell (MATCHES . COMPLETE-P), where MATCHES is a list of
up to MAX-RESULTS propertized candidate strings and COMPLETE-P is non-nil
if the entire buffer was scanned without hitting the limit."
  (let* ((limit (or max-results compuni-max-candidates))
         (terms (split-string (downcase query) "[[:space:]]+" t))
         (matches nil)
         (count 0)
         (complete t))
    (with-current-buffer buffer
      (save-excursion
        (let ((case-fold-search nil))
          (goto-char (point-min))
          (if (null terms)
              (while (and (not (eobp)) (< count limit))
                (let* ((bol (point))
                       (eol (line-end-position))
                       (tab (search-forward "\t" eol t)))
                  (when tab
                    (push (compuni--make-candidate
                           (buffer-substring-no-properties bol (1- tab))
                           (buffer-substring-no-properties tab eol))
                          matches)
                    (setq count (1+ count))))
                (forward-line 1))
            ;; Sort longest term first so C `search-forward' skips maximally.
            (let* ((sorted (sort (copy-sequence terms)
                                 (lambda (a b) (> (length a) (length b)))))
                   (primary (car sorted))
                   (rest (cdr sorted)))
              (while (and (< count limit)
                          (search-forward primary nil t))
                (let* ((match-end (point))
                       (bol (line-beginning-position))
                       (eol (line-end-position))
                       (tab (save-excursion
                              (goto-char bol)
                              (search-forward "\t" eol t))))
                  (when (and tab (<= match-end (1- tab)))
                    (let ((name (buffer-substring-no-properties bol (1- tab))))
                      (when (or (null rest)
                                (cl-every (lambda (term) (string-search term name))
                                          rest))
                        (push (compuni--make-candidate
                               name
                               (buffer-substring-no-properties tab eol))
                              matches)
                        (setq count (1+ count))))))
                (forward-line 1))))
          (when (and (>= count limit) (not (eobp)))
            (setq complete nil)))))
    (cons (nreverse matches) complete)))

(defun compuni--narrowing-p (old-terms new-terms)
  "Return non-nil if NEW-TERMS is at least as restrictive as OLD-TERMS."
  (cl-every (lambda (old)
              (cl-some (lambda (new) (string-search old new))
                       new-terms))
            old-terms))

;;; Session State & Ephemeral Company Backend

(cl-defstruct compuni--session
  "Buffer-local state for an active ephemeral completion session."
  buffer
  start-marker
  prev-company-mode
  last-terms
  last-matches
  last-complete)

(defvar-local compuni--active-session nil
  "Active `compuni--session' for the current buffer, or nil.")

(defun compuni--query-session (query session)
  "Query SESSION for QUERY, using incremental narrowing when safe."
  (let* ((terms (split-string (downcase query) "[[:space:]]+" t))
         (last-complete (compuni--session-last-complete session))
         (last-terms (compuni--session-last-terms session))
         (last-matches (compuni--session-last-matches session)))
    (if (and last-complete
             (compuni--narrowing-p last-terms terms))
        (let ((narrowed
               (cl-remove-if-not
                (lambda (cand)
                  (cl-every (lambda (term) (string-search term cand)) terms))
                last-matches)))
          (setf (compuni--session-last-terms session) terms
                (compuni--session-last-matches session) narrowed
                (compuni--session-last-complete session) t)
          narrowed)
      (let* ((res (compuni--filter-buffer
                   query
                   (compuni--session-buffer session)
                   compuni-max-candidates))
             (matches (car res))
             (complete (cdr res)))
        (setf (compuni--session-last-terms session) terms
              (compuni--session-last-matches session) matches
              (compuni--session-last-complete session) complete)
        matches))))

(defun compuni--cleanup (&optional _ignored)
  "Tear down the active compuni session and restore prior `company-mode' state."
  (remove-hook 'company-after-completion-hook #'compuni--cleanup t)
  (when compuni--active-session
    (let ((marker (compuni--session-start-marker compuni--active-session))
          (was-active (compuni--session-prev-company-mode compuni--active-session)))
      (when (markerp marker)
        (set-marker marker nil))
      (setq compuni--active-session nil)
      (unless was-active
        (company-mode -1)))))

(defun compuni--company-backend (command &optional arg &rest _ignored)
  "Ephemeral `company-mode' backend for compuni.
COMMAND and ARG follow the standard `company-backends' protocol."
  (interactive (list 'interactive))
  (cl-case command
    (interactive (company-begin-backend #'compuni--company-backend))
    (prefix
     (when compuni--active-session
       (let ((start (compuni--session-start-marker compuni--active-session)))
         (when (and (markerp start) (>= (point) start))
           (cons (buffer-substring-no-properties start (point)) t)))))
    (candidates
     (when compuni--active-session
       (compuni--query-session arg compuni--active-session)))
    (annotation
     (when-let* ((char (compuni--candidate-char arg)))
       (format compuni-annotation-format char)))
    (post-completion
     (when compuni--active-session
       (let ((start (compuni--session-start-marker compuni--active-session))
             (char (compuni--candidate-char arg)))
         (when (and char (markerp start) (>= (point) start))
           (delete-region start (point))
           (insert char)))))
    (no-cache t)
    (ignore-case t)))

(defun compuni--start (buffer-fn)
  "Start an ephemeral completion session using BUFFER-FN."
  (when compuni--active-session
    (compuni--cleanup))
  (let* ((bounds (cond
                  ((use-region-p) (cons (region-beginning) (region-end)))
                  ((bounds-of-thing-at-point 'word))
                  (t (cons (point) (point)))))
         (start (car bounds))
         (end (cdr bounds))
         (was-active (bound-and-true-p company-mode))
         (dataset-buf (funcall buffer-fn)))
    (when (use-region-p)
      (deactivate-mark))
    (goto-char end)
    ;; Dismiss any pre-existing company completion BEFORE installing our
    ;; session and hook; otherwise `company-begin-backend's internal
    ;; `company-cancel' fires `compuni--cleanup' and wipes the new session.
    (when was-active
      (company-cancel))
    (setq compuni--active-session
          (make-compuni--session :buffer dataset-buf
                                 :start-marker (copy-marker start)
                                 :prev-company-mode was-active))
    (add-hook 'company-after-completion-hook #'compuni--cleanup nil t)
    (unless was-active
      (company-mode 1))
    ;; Safeguard: clean up immediately if company fails to start (e.g., 0 matches).
    (let ((started nil))
      (unwind-protect
          (condition-case nil
              (progn
                (company-begin-backend #'compuni--company-backend)
                (setq started (and (bound-and-true-p company-candidates) t)))
            (user-error nil))
        (unless started
          (compuni--cleanup)
          (message "Compuni: No matching candidates"))))))

;;; Public Commands

;;;###autoload
(defun compuni-insert-unicode ()
  "Search and insert a Unicode character at point using an ephemeral popup."
  (interactive)
  (compuni--start #'compuni--get-unicode-buffer))

;;;###autoload
(defun compuni-insert-emoji ()
  "Search and insert an Emoji at point using an ephemeral popup."
  (interactive)
  (compuni--start #'compuni--get-emoji-buffer))

(provide 'compuni)

;;; compuni.el ends here
