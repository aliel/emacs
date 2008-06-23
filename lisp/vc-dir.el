;;; vc-dir.el --- Directory status display under VC

;; Copyright (C) 2007, 2008
;;   Free Software Foundation, Inc.

;; Author:   Dan Nicolaescu <dann@ics.uci.edu>
;; Keywords: tools

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Credits:

;; The original VC directory status implementation was based on dired.
;; This implementation was inspired by PCL-CVS.
;; Many people contributed comments, ideas and code to this
;; implementation.  These include:
;; 
;;   Alexandre Julliard  <julliard@winehq.org>
;;   Stefan Monnier  <monnier@iro.umontreal.ca>
;;   Tom Tromey  <tromey@redhat.com>

;;; Commentary:
;; 

;;; Todo:  see vc.el.

(require 'vc-hooks)
(require 'vc)
(require 'ewoc)

;;; Code:
(eval-when-compile
  (require 'cl))

(defcustom vc-dir-mode-hook nil
  "Normal hook run by `vc-dir-mode'.
See `run-hooks'."
  :type 'hook
  :group 'vc)

;; Used to store information for the files displayed in the directory buffer.
;; Each item displayed corresponds to one of these defstructs.
(defstruct (vc-dir-fileinfo
            (:copier nil)
            (:type list)            ;So we can use `member' on lists of FIs.
            (:constructor
             ;; We could define it as an alias for `list'.
	     vc-dir-create-fileinfo (name state &optional extra marked directory))
            (:conc-name vc-dir-fileinfo->))
  name                                  ;Keep it as first, for `member'.
  state
  ;; For storing client-mode specific information.
  extra
  marked
  ;; To keep track of not updated files during a global refresh
  needs-update
  ;; To distinguish files and directories.
  directory)

;; Used to describe a dispatcher client mode.
(defstruct (vc-client-object
            (:copier nil)
            (:constructor
	     vc-create-client-object (name
				      headers
				      file-to-info
				      file-to-state
				      file-to-extra
				      updater
				      extra-menu))
            (:conc-name vc-client-object->))
  name
  headers
  file-to-info
  file-to-state
  file-to-extra
  updater
  extra-menu)

(defvar vc-ewoc nil)
(defvar vc-dir-process-buffer nil
  "The buffer used for the asynchronous call that computes status.")

(defun vc-dir-move-to-goal-column ()
  ;; Used to keep the cursor on the file name column.
  (beginning-of-line)
  (unless (eolp)
    ;; Must be in sync with vc-default-status-printer.
    (forward-char 25)))

(defun vc-dir-prepare-status-buffer (bname dir &optional create-new)
  "Find a buffer named BNAME showing DIR, or create a new one."
  (setq dir (expand-file-name dir))
  (let*
	 ;; Look for another buffer name BNAME visiting the same directory.
	 ((buf (save-excursion
		(unless create-new
		  (dolist (buffer (buffer-list))
		    (set-buffer buffer)
		    (when (and (vc-dispatcher-browsing)
			       (string= (expand-file-name default-directory) dir))
		      (return buffer)))))))
    (or buf
        ;; Create a new buffer named BNAME.
        (with-current-buffer (create-file-buffer bname)
          (cd dir)
          (vc-setup-buffer (current-buffer))
          ;; Reset the vc-parent-buffer-name so that it does not appear
          ;; in the mode-line.
          (setq vc-parent-buffer-name nil)
          (current-buffer)))))

(defvar vc-dir-menu-map
  (let ((map (make-sparse-keymap "VC-dir")))
    (define-key map [quit]
      '(menu-item "Quit" quit-window
		  :help "Quit"))
    (define-key map [kill]
      '(menu-item "Kill Update Command" vc-dir-kill-dir-status-process
		  :enable (vc-dir-busy)
		  :help "Kill the command that updates the directory buffer"))
    (define-key map [refresh]
      '(menu-item "Refresh" vc-dir-refresh
		  :enable (not (vc-dir-busy))
		  :help "Refresh the contents of the directory buffer"))
    ;; Movement.
    (define-key map [sepmv] '("--"))
    (define-key map [next-line]
      '(menu-item "Next line" vc-dir-next-line
		  :help "Go to the next line" :keys "n"))
    (define-key map [previous-line]
      '(menu-item "Previous line" vc-dir-previous-line
		  :help "Go to the previous line"))
    ;; Marking.
    (define-key map [sepmrk] '("--"))
    (define-key map [unmark-all]
      '(menu-item "Unmark All" vc-dir-unmark-all-files
		  :help "Unmark all files that are in the same state as the current file\
\nWith prefix argument unmark all files"))
    (define-key map [unmark-previous]
      '(menu-item "Unmark previous " vc-dir-unmark-file-up
		  :help "Move to the previous line and unmark the file"))

    (define-key map [mark-all]
      '(menu-item "Mark All" vc-dir-mark-all-files
		  :help "Mark all files that are in the same state as the current file\
\nWith prefix argument mark all files"))
    (define-key map [unmark]
      '(menu-item "Unmark" vc-dir-unmark
		  :help "Unmark the current file or all files in the region"))

    (define-key map [mark]
      '(menu-item "Mark" vc-dir-mark
		  :help "Mark the current file or all files in the region"))

    (define-key map [sepopn] '("--"))
    (define-key map [open-other]
      '(menu-item "Open in other window" vc-dir-find-file-other-window
		  :help "Find the file on the current line, in another window"))
    (define-key map [open]
      '(menu-item "Open file" vc-dir-find-file
		  :help "Find the file on the current line"))
    map)
  "Menu for dispatcher status")

(defvar vc-client-mode)

;; This is used so that client modes can add mode-specific menu
;; items to vc-dir-menu-map.
(defun vc-dir-menu-map-filter (orig-binding)
  (when (and (symbolp orig-binding) (fboundp orig-binding))
    (setq orig-binding (indirect-function orig-binding)))
  (let ((ext-binding
         ;; This may be executed at load-time for tool-bar-local-item-from-menu
         ;; but at that time vc-client-mode is not known (or even bound) yet.
         (when (and (boundp 'vc-client-mode) vc-client-mode)
           (funcall (vc-client-object->extra-menu vc-client-mode)))))
    (if (null ext-binding)
	orig-binding
      (append orig-binding
	      '("----")
	      ext-binding))))

(defvar vc-dir-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map)
    ;; Marking.
    (define-key map "m" 'vc-dir-mark)
    (define-key map "M" 'vc-dir-mark-all-files)
    (define-key map "u" 'vc-dir-unmark)
    (define-key map "U" 'vc-dir-unmark-all-files)
    (define-key map "\C-?" 'vc-dir-unmark-file-up)
    (define-key map "\M-\C-?" 'vc-dir-unmark-all-files)
    ;; Movement.
    (define-key map "n" 'vc-dir-next-line)
    (define-key map " " 'vc-dir-next-line)
    (define-key map "\t" 'vc-dir-next-directory)
    (define-key map "p" 'vc-dir-previous-line)
    (define-key map [backtab] 'vc-dir-previous-directory)
    ;;; Rebind paragraph-movement commands.
    (define-key map "\M-}" 'vc-dir-next-directory)
    (define-key map "\M-{" 'vc-dir-previous-directory)
    (define-key map [C-down] 'vc-dir-next-directory)
    (define-key map [C-up] 'vc-dir-previous-directory)
    ;; The remainder.
    (define-key map "f" 'vc-dir-find-file)
    (define-key map "\C-m" 'vc-dir-find-file)
    (define-key map "o" 'vc-dir-find-file-other-window)
    (define-key map "q" 'quit-window)
    (define-key map "g" 'vc-dir-refresh)
    (define-key map "\C-c\C-c" 'vc-dir-kill-dir-status-process)
    (define-key map [down-mouse-3] 'vc-dir-menu)
    (define-key map [mouse-2] 'vc-dir-toggle-mark)

    ;; Hook up the menu.
    (define-key map [menu-bar vc-dir-mode]
      `(menu-item
	;; This is used so that client modes can add mode-specific
	;; menu items to vc-dir-menu-map.
	"VC-dir" ,vc-dir-menu-map :filter vc-dir-menu-map-filter))
    map)
  "Keymap for directory buffer.")

(defmacro vc-at-event (event &rest body)
  "Evaluate `body' with point located at event-start of `event'.
If `body' uses `event', it should be a variable,
 otherwise it will be evaluated twice."
  (let ((posn (make-symbol "vc-at-event-posn")))
    `(let ((,posn (event-start ,event)))
       (save-excursion
         (set-buffer (window-buffer (posn-window ,posn)))
         (goto-char (posn-point ,posn))
         ,@body))))

(defun vc-dir-menu (e)
  "Popup the dispatcher status menu."
  (interactive "e")
  (vc-at-event e (popup-menu vc-dir-menu-map e)))

(defvar vc-dir-tool-bar-map
  (let ((map (make-sparse-keymap)))
    (tool-bar-local-item-from-menu 'vc-dir-find-file "open"
				   map vc-dir-mode-map)
    (tool-bar-local-item "bookmark_add"
			 'vc-dir-toggle-mark 'vc-dir-toggle-mark map
			 :help "Toggle mark on current item")
    (tool-bar-local-item-from-menu 'vc-dir-previous-line "left-arrow"
				   map vc-dir-mode-map
				   :rtl "right-arrow")
    (tool-bar-local-item-from-menu 'vc-dir-next-line "right-arrow"
				   map vc-dir-mode-map
				   :rtl "left-arrow")
    (tool-bar-local-item-from-menu 'vc-print-log "info"
				   map vc-dir-mode-map)
    (tool-bar-local-item-from-menu 'vc-dir-refresh "refresh"
				   map vc-dir-mode-map)
    (tool-bar-local-item-from-menu 'nonincremental-search-forward
				   "search" map)
    (tool-bar-local-item-from-menu 'vc-dir-kill-dir-status-process "cancel"
				   map vc-dir-mode-map)
    (tool-bar-local-item-from-menu 'quit-window "exit"
				   map vc-dir-mode-map)
    map))

(defun vc-dir-node-directory (node)
  ;; Compute the directory for NODE.
  ;; If it's a directory node, get it from the the node.
  (let ((data (ewoc-data node)))
    (or (vc-dir-fileinfo->directory data)
	;; Otherwise compute it from the file name.
	(file-name-directory
	 (expand-file-name
	  (vc-dir-fileinfo->name data))))))

(defun vc-dir-update (entries buffer &optional noinsert)
  "Update BUFFER's ewoc from the list of ENTRIES.
If NOINSERT, ignore elements on ENTRIES which are not in the ewoc."
  ;; Add ENTRIES to the vc-dir buffer BUFFER.
  (with-current-buffer buffer
    ;; Insert the entries sorted by name into the ewoc.
    ;; We assume the ewoc is sorted too, which should be the
    ;; case if we always add entries with vc-dir-update.
    (setq entries
	  ;; Sort: first files and then subdirectories.
	  ;; XXX: this is VERY inefficient, it computes the directory
	  ;; names too many times
	  (sort entries
		(lambda (entry1 entry2)
		  (let ((dir1 (file-name-directory (expand-file-name (car entry1))))
			(dir2 (file-name-directory (expand-file-name (car entry2)))))
		    (cond
		     ((string< dir1 dir2) t)
		     ((not (string= dir1 dir2)) nil)
		     ((string< (car entry1) (car entry2))))))))
    ;; Insert directory entries in the right places.
    (let ((entry (car entries))
	  (node (ewoc-nth vc-ewoc 0)))
      ;; Insert . if it is not present.
      (unless node
	(let ((rd (file-relative-name default-directory)))
	  (ewoc-enter-last
	   vc-ewoc (vc-dir-create-fileinfo
		    rd nil nil nil (expand-file-name default-directory))))
	(setq node (ewoc-nth vc-ewoc 0)))
      
      (while (and entry node)
	(let* ((entryfile (car entry))
	       (entrydir (file-name-directory (expand-file-name entryfile)))
	       (nodedir (vc-dir-node-directory node)))
	  (cond
	   ;; First try to find the directory.
	   ((string-lessp nodedir entrydir)
	    (setq node (ewoc-next vc-ewoc node)))
	   ((string-equal nodedir entrydir)
	    ;; Found the directory, find the place for the file name.
	    (let ((nodefile (vc-dir-fileinfo->name (ewoc-data node))))
	      (cond
	       ((string-lessp nodefile entryfile)
		(setq node (ewoc-next vc-ewoc node)))
	       ((string-equal nodefile entryfile)
		(setf (vc-dir-fileinfo->state (ewoc-data node)) (nth 1 entry))
		(setf (vc-dir-fileinfo->extra (ewoc-data node)) (nth 2 entry))
		(setf (vc-dir-fileinfo->needs-update (ewoc-data node)) nil)
		(ewoc-invalidate vc-ewoc node)
		(setq entries (cdr entries)) 
		(setq entry (car entries))
		(setq node (ewoc-next vc-ewoc node)))
	       (t
		(ewoc-enter-before vc-ewoc node
				   (apply 'vc-dir-create-fileinfo entry))
		(setq entries (cdr entries))
		(setq entry (car entries))))))
	   (t
	    ;; We might need to insert a directory node if the
	    ;; previous node was in a different directory.
	    (let* ((rd (file-relative-name entrydir))
		   (prev-node (ewoc-prev vc-ewoc node))
		   (prev-dir (vc-dir-node-directory prev-node)))
	      (unless (string-equal entrydir prev-dir)
		(ewoc-enter-before
		 vc-ewoc node (vc-dir-create-fileinfo rd nil nil nil entrydir))))
	    ;; Now insert the node itself.
	    (ewoc-enter-before vc-ewoc node
			       (apply 'vc-dir-create-fileinfo entry))
	    (setq entries (cdr entries) entry (car entries))))))
      ;; We're past the last node, all remaining entries go to the end.
      (unless (or node noinsert)
	(let ((lastdir (vc-dir-node-directory (ewoc-nth vc-ewoc -1))))
	  (dolist (entry entries)
	    (let ((entrydir (file-name-directory (expand-file-name (car entry)))))
	      ;; Insert a directory node if needed.
	      (unless (string-equal lastdir entrydir)
		(setq lastdir entrydir)
		(let ((rd (file-relative-name entrydir)))
		  (ewoc-enter-last
		   vc-ewoc (vc-dir-create-fileinfo rd nil nil nil entrydir))))
	      ;; Now insert the node itself.
	      (ewoc-enter-last vc-ewoc
			       (apply 'vc-dir-create-fileinfo entry)))))))))

(defun vc-dir-busy ()
  (and (buffer-live-p vc-dir-process-buffer)
       (get-buffer-process vc-dir-process-buffer)))

(defun vc-dir-kill-dir-status-process ()
  "Kill the temporary buffer and associated process."
  (interactive)
  (when (buffer-live-p vc-dir-process-buffer)
    (let ((proc (get-buffer-process vc-dir-process-buffer)))
      (when proc (delete-process proc))
      (setq vc-dir-process-buffer nil)
      (setq mode-line-process nil))))

(defun vc-dir-kill-query ()
  ;; Make sure that when the status buffer is killed the update
  ;; process running in background is also killed.
  (if (vc-dir-busy)
    (when (y-or-n-p "Status update process running, really kill status buffer? ")
      (vc-dir-kill-dir-status-process)
      t)
    t))

(defun vc-dir-next-line (arg)
  "Go to the next line.
If a prefix argument is given, move by that many lines."
  (interactive "p")
  (with-no-warnings
    (ewoc-goto-next vc-ewoc arg)
    (vc-dir-move-to-goal-column)))

(defun vc-dir-previous-line (arg)
  "Go to the previous line.
If a prefix argument is given, move by that many lines."
  (interactive "p")
  (ewoc-goto-prev vc-ewoc arg)
  (vc-dir-move-to-goal-column))

(defun vc-dir-next-directory ()
  "Go to the next directory."
  (interactive)
  (let ((orig (point)))
    (if
	(catch 'foundit
	  (while t
	    (let* ((next (ewoc-next vc-ewoc (ewoc-locate vc-ewoc))))
	      (cond ((not next)
		     (throw 'foundit t))
		    (t
		     (progn
		       (ewoc-goto-node vc-ewoc next)
		       (vc-dir-move-to-goal-column)
		       (if (vc-dir-fileinfo->directory (ewoc-data next))
			   (throw 'foundit nil))))))))
	(goto-char orig))))

(defun vc-dir-previous-directory ()
  "Go to the previous directory."
  (interactive)
  (let ((orig (point)))
    (if
	(catch 'foundit
	  (while t
	    (let* ((prev (ewoc-prev vc-ewoc (ewoc-locate vc-ewoc))))
	      (cond ((not prev)
		     (throw 'foundit t))
		    (t
		     (progn
		       (ewoc-goto-node vc-ewoc prev)
		       (vc-dir-move-to-goal-column)
		       (if (vc-dir-fileinfo->directory (ewoc-data prev))
			   (throw 'foundit nil))))))))
	(goto-char orig))))

(defun vc-dir-mark-unmark (mark-unmark-function)
  (if (use-region-p)
      (let ((firstl (line-number-at-pos (region-beginning)))
	    (lastl (line-number-at-pos (region-end))))
	(save-excursion
	  (goto-char (region-beginning))
	  (while (<= (line-number-at-pos) lastl)
	    (funcall mark-unmark-function))))
    (funcall mark-unmark-function)))

(defun vc-string-prefix-p (prefix string)
  (let ((lpref (length prefix)))
    (and (>= (length string) lpref)
	 (eq t (compare-strings prefix nil nil string nil lpref)))))

(defun vc-dir-parent-marked-p (arg)
  ;; Return nil if none of the parent directories of arg is marked.
  (let* ((argdir (vc-dir-node-directory arg))
	 (arglen (length argdir))
	 (crt arg)
	 data dir)
    ;; Go through the predecessors, checking if any directory that is
    ;; a parent is marked.
    (while (setq crt (ewoc-prev vc-ewoc crt))
      (setq data (ewoc-data crt))
      (setq dir (vc-dir-node-directory crt))
      (when (and (vc-dir-fileinfo->directory data)
		 (vc-string-prefix-p dir argdir))
	(when (vc-dir-fileinfo->marked data)
	  (error "Cannot mark `%s', parent directory `%s' marked"
		 (vc-dir-fileinfo->name (ewoc-data arg))
		 (vc-dir-fileinfo->name data)))))
    nil))

(defun vc-dir-children-marked-p (arg)
  ;; Return nil if none of the children of arg is marked.
  (let* ((argdir-re (concat "\\`" (regexp-quote (vc-dir-node-directory arg))))
	 (is-child t)
	 (crt arg)
	 data dir)
    (while (and is-child (setq crt (ewoc-next vc-ewoc crt)))
      (setq data (ewoc-data crt))
      (setq dir (vc-dir-node-directory crt))
      (if (string-match argdir-re dir)
	  (when (vc-dir-fileinfo->marked data)
	    (error "Cannot mark `%s', child `%s' marked"
		   (vc-dir-fileinfo->name (ewoc-data arg))
		   (vc-dir-fileinfo->name data)))
	;; We are done, we got to an entry that is not a child of `arg'.
	(setq is-child nil)))
    nil))

(defun vc-dir-mark-file (&optional arg)
  ;; Mark ARG or the current file and move to the next line.
  (let* ((crt (or arg (ewoc-locate vc-ewoc)))
         (file (ewoc-data crt))
	 (isdir (vc-dir-fileinfo->directory file)))
    (when (or (and isdir (not (vc-dir-children-marked-p crt)))
	      (and (not isdir) (not (vc-dir-parent-marked-p crt))))
      (setf (vc-dir-fileinfo->marked file) t)
      (ewoc-invalidate vc-ewoc crt)
      (unless (or arg (mouse-event-p last-command-event))
	(vc-dir-next-line 1)))))

(defun vc-dir-mark ()
  "Mark the current file or all files in the region.
If the region is active, mark all the files in the region.
Otherwise mark the file on the current line and move to the next
line."
  (interactive)
  (vc-dir-mark-unmark 'vc-dir-mark-file))

(defun vc-dir-mark-all-files (arg)
  "Mark all files with the same state as the current one.
With a prefix argument mark all files.
If the current entry is a directory, mark all child files.

The commands operate on files that are on the same state.
This command is intended to make it easy to select all files that
share the same state."
  (interactive "P")
  (if arg
      ;; Mark all files.
      (progn
	;; First check that no directory is marked, we can't mark
	;; files in that case.
	(ewoc-map
	 (lambda (filearg)
	   (when (and (vc-dir-fileinfo->directory filearg)
		      (vc-dir-fileinfo->marked filearg))
	     (error "Cannot mark all files, directory `%s' marked"
		    (vc-dir-fileinfo->name filearg))))
	 vc-ewoc)
	(ewoc-map
	 (lambda (filearg)
	   (unless (vc-dir-fileinfo->marked filearg)
	     (setf (vc-dir-fileinfo->marked filearg) t)
	     t))
	 vc-ewoc))
    (let ((data (ewoc-data (ewoc-locate vc-ewoc))))
      (if (vc-dir-fileinfo->directory data)
	  ;; It's a directory, mark child files.
	  (let ((crt (ewoc-locate vc-ewoc)))
	    (unless (vc-dir-children-marked-p crt)
	      (while (setq crt (ewoc-next vc-ewoc crt))
		(let ((crt-data (ewoc-data crt)))
		  (unless (vc-dir-fileinfo->directory crt-data)
		    (setf (vc-dir-fileinfo->marked crt-data) t)
		    (ewoc-invalidate vc-ewoc crt))))))
	;; It's a file
	(let ((state (vc-dir-fileinfo->state data))
	      (crt (ewoc-nth vc-ewoc 0)))
	  (while crt
	    (let ((crt-data (ewoc-data crt)))
	      (when (and (not (vc-dir-fileinfo->marked crt-data))
			 (eq (vc-dir-fileinfo->state crt-data) state)
			 (not (vc-dir-fileinfo->directory crt-data)))
		(vc-dir-mark-file crt)))
	    (setq crt (ewoc-next vc-ewoc crt))))))))

(defun vc-dir-unmark-file ()
  ;; Unmark the current file and move to the next line.
  (let* ((crt (ewoc-locate vc-ewoc))
         (file (ewoc-data crt)))
    (setf (vc-dir-fileinfo->marked file) nil)
    (ewoc-invalidate vc-ewoc crt)
    (unless (mouse-event-p last-command-event)
      (vc-dir-next-line 1))))

(defun vc-dir-unmark ()
  "Unmark the current file or all files in the region.
If the region is active, unmark all the files in the region.
Otherwise mark the file on the current line and move to the next
line."
  (interactive)
  (vc-dir-mark-unmark 'vc-dir-unmark-file))

(defun vc-dir-unmark-file-up ()
  "Move to the previous line and unmark the file."
  (interactive)
  ;; If we're on the first line, we won't move up, but we will still
  ;; remove the mark.  This seems a bit odd but it is what buffer-menu
  ;; does.
  (let* ((prev (ewoc-goto-prev vc-ewoc 1))
	 (file (ewoc-data prev)))
    (setf (vc-dir-fileinfo->marked file) nil)
    (ewoc-invalidate vc-ewoc prev)
    (vc-dir-move-to-goal-column)))

(defun vc-dir-unmark-all-files (arg)
  "Unmark all files with the same state as the current one.
With a prefix argument unmark all files.
If the current entry is a directory, unmark all the child files.

The commands operate on files that are on the same state.
This command is intended to make it easy to deselect all files
that share the same state."
  (interactive "P")
  (if arg
      (ewoc-map
       (lambda (filearg)
	 (when (vc-dir-fileinfo->marked filearg)
	   (setf (vc-dir-fileinfo->marked filearg) nil)
	   t))
       vc-ewoc)
    (let* ((crt (ewoc-locate vc-ewoc))
	   (data (ewoc-data crt)))
      (if (vc-dir-fileinfo->directory data)
	  ;; It's a directory, unmark child files.
	  (while (setq crt (ewoc-next vc-ewoc crt))
	    (let ((crt-data (ewoc-data crt)))
	      (unless (vc-dir-fileinfo->directory crt-data)
		(setf (vc-dir-fileinfo->marked crt-data) nil)
		(ewoc-invalidate vc-ewoc crt))))
	;; It's a file
	(let ((crt-state (vc-dir-fileinfo->state (ewoc-data crt))))
	  (ewoc-map
	   (lambda (filearg)
	     (when (and (vc-dir-fileinfo->marked filearg)
			(eq (vc-dir-fileinfo->state filearg) crt-state))
	       (setf (vc-dir-fileinfo->marked filearg) nil)
	       t))
	   vc-ewoc))))))

(defun vc-dir-toggle-mark-file ()
  (let* ((crt (ewoc-locate vc-ewoc))
         (file (ewoc-data crt)))
    (if (vc-dir-fileinfo->marked file)
	(vc-dir-unmark-file)
      (vc-dir-mark-file))))

(defun vc-dir-toggle-mark (e)
  (interactive "e")
  (vc-at-event e (vc-dir-mark-unmark 'vc-dir-toggle-mark-file)))

(defun vc-dir-delete-file ()
  "Delete the marked files, or the current file if no marks."
  (interactive)
  (mapc 'vc-delete-file (or (vc-dir-marked-files)
                            (list (vc-dir-current-file)))))

(defun vc-dir-find-file ()
  "Find the file on the current line."
  (interactive)
  (find-file (vc-dir-current-file)))

(defun vc-dir-find-file-other-window ()
  "Find the file on the current line, in another window."
  (interactive)
  (find-file-other-window (vc-dir-current-file)))

(defun vc-dir-current-file ()
  (let ((node (ewoc-locate vc-ewoc)))
    (unless node
      (error "No file available"))
    (expand-file-name (vc-dir-fileinfo->name (ewoc-data node)))))

(defun vc-dir-marked-files ()
  "Return the list of marked files."
  (mapcar
   (lambda (elem) (expand-file-name (vc-dir-fileinfo->name elem)))
   (ewoc-collect vc-ewoc 'vc-dir-fileinfo->marked)))

(defun vc-dir-marked-only-files ()
  "Return the list of marked files, for marked directories return child files."
  (let ((crt (ewoc-nth vc-ewoc 0))
	result)
    (while crt
      (let ((crt-data (ewoc-data crt)))
	(if (vc-dir-fileinfo->marked crt-data)
	    ;; FIXME: use vc-dir-child-files here instead of duplicating it.
	    (if (vc-dir-fileinfo->directory crt-data)
		(let* ((dir (vc-dir-fileinfo->directory crt-data))
		       (dirlen (length dir))
		       data)
		  (while
		      (and (setq crt (ewoc-next vc-ewoc crt))
			   (vc-string-prefix-p dir
                                               (progn
                                                 (setq data (ewoc-data crt))
                                                 (vc-dir-node-directory crt))))
		    (unless (vc-dir-fileinfo->directory data)
		      (push (expand-file-name (vc-dir-fileinfo->name data)) result))))
	      (push (expand-file-name (vc-dir-fileinfo->name crt-data)) result)
	      (setq crt (ewoc-next vc-ewoc crt)))
	  (setq crt (ewoc-next vc-ewoc crt)))))
    result))

(defun vc-dir-child-files ()
  "Return the list of child files for the current entry if it's a directory.
If it is a file, return the file itself."
  (let* ((crt (ewoc-locate vc-ewoc))
	 (crt-data (ewoc-data crt))
         result)
    (if (vc-dir-fileinfo->directory crt-data)
	(let* ((dir (vc-dir-fileinfo->directory crt-data))
	       (dirlen (length dir))
	       data)
	  (while
	      (and (setq crt (ewoc-next vc-ewoc crt))
                   (vc-string-prefix-p dir (progn
                                             (setq data (ewoc-data crt))
                                             (vc-dir-node-directory crt))))
	    (unless (vc-dir-fileinfo->directory data)
	      (push (expand-file-name (vc-dir-fileinfo->name data)) result))))
      (push (expand-file-name (vc-dir-fileinfo->name crt-data)) result))
    result))

(defun vc-dir-resynch-file (&optional fname)
  "Update the entries for FILE in any directory buffers that list it."
  (let ((file (or fname (expand-file-name buffer-file-name))))
    (if (file-directory-p file)
	;; FIXME: Maybe this should never happen? 
        ;; FIXME: But it is useful to update the state of a directory
	;; (more precisely the files in the directory) after some VC
	;; operations.
	nil
      (let ((found-vc-dir-buf nil))
	(save-excursion
	  (dolist (status-buf (buffer-list))
	    (set-buffer status-buf)
	    ;; look for a vc-dir buffer that might show this file.
	    (when (derived-mode-p 'vc-dir-mode)
	      (setq found-vc-dir-buf t)
	      (let ((ddir (expand-file-name default-directory)))
		(when (vc-string-prefix-p ddir file)
		  (let*
                      ;; FIXME: Any reason we don't use file-relative-name?
		      ((file-short (substring file (length ddir)))
		       (state (funcall (vc-client-object->file-to-state
                                        vc-client-mode)
				 file))
		       (extra (funcall (vc-client-object->file-to-extra
                                        vc-client-mode)
				 file))
		       (entry
			(list file-short state extra)))
		    (vc-dir-update (list entry) status-buf))))))
	  ;; We didn't find any vc-dir buffers, remove the hook, it is
	  ;; not needed.
	  (unless found-vc-dir-buf
            (remove-hook 'after-save-hook 'vc-dir-resynch-file)))))))

(defun vc-dir-mode (client-object)
  "Major mode for dispatcher directory buffers.
Marking/Unmarking key bindings and actions:
m - marks a file/directory or if the region is active, mark all the files
     in region.
    Restrictions: - a file cannot be marked if any parent directory is marked
                  - a directory cannot be marked if any child file or
                    directory is marked
u - marks a file/directory or if the region is active, unmark all the files
     in region.
M - if the cursor is on a file: mark all the files with the same state as
      the current file
  - if the cursor is on a directory: mark all child files
  - with a prefix argument: mark all files
U - if the cursor is on a file: unmark all the files with the same state
      as the current file
  - if the cursor is on a directory: unmark all child files
  - with a prefix argument: unmark all files


\\{vc-dir-mode-map}"
  (setq mode-name (vc-client-object->name client-object))
  (setq major-mode 'vc-dir-mode)
  (setq buffer-read-only t)
  (use-local-map vc-dir-mode-map)
  (if (boundp 'tool-bar-map)
      (set (make-local-variable 'tool-bar-map) vc-dir-tool-bar-map))
  (set (make-local-variable 'vc-client-mode) client-object)
  (let ((buffer-read-only nil))
    (erase-buffer)
    (set (make-local-variable 'vc-dir-process-buffer) nil)
    (set (make-local-variable 'vc-ewoc)
	 (ewoc-create (vc-client-object->file-to-info client-object)
		      (vc-client-object->headers client-object)))
    (add-hook 'after-save-hook 'vc-dir-resynch-file)
    ;; Make sure that if the directory buffer is killed, the update
    ;; process running in the background is also killed.
    (add-hook 'kill-buffer-query-functions 'vc-dir-kill-query nil t)
    (funcall (vc-client-object->updater client-object)))
  (run-hooks 'vc-dir-mode-hook))

(put 'vc-dir-mode 'mode-class 'special)

(defvar vc-dir-backend nil
  "The backend used by the current *vc-dir* buffer.")

(defun vc-dir-headers (backend dir)
  "Display the headers in the *VC dir* buffer.
It calls the `status-extra-headers' backend method to display backend
specific headers."
  (concat
   (propertize "VC backend : " 'face 'font-lock-type-face)
   (propertize (format "%s\n" backend) 'face 'font-lock-variable-name-face)
   (propertize "Working dir: " 'face 'font-lock-type-face)
   (propertize (format "%s\n" dir) 'face 'font-lock-variable-name-face)
   (vc-call-backend backend 'status-extra-headers dir)
   "\n"))

(defun vc-dir-refresh-files (files default-state)
  "Refresh some files in the *VC-dir* buffer."
  (let ((def-dir default-directory)
	(backend vc-dir-backend))
    (vc-set-mode-line-busy-indicator)
    ;; Call the `dir-status-file' backend function.
    ;; `dir-status-file' is supposed to be asynchronous.
    ;; It should compute the results, and then call the function
    ;; passed as an argument in order to update the vc-dir buffer
    ;; with the results.
    (unless (buffer-live-p vc-dir-process-buffer)
      (setq vc-dir-process-buffer
            (generate-new-buffer (format " *VC-%s* tmp status" backend))))
    (lexical-let ((buffer (current-buffer)))
      (with-current-buffer vc-dir-process-buffer
        (cd def-dir)
        (erase-buffer)
        (vc-call-backend
         backend 'dir-status-files def-dir files default-state
         (lambda (entries &optional more-to-come)
           ;; ENTRIES is a list of (FILE VC_STATE EXTRA) items.
           ;; If MORE-TO-COME is true, then more updates will come from
           ;; the asynchronous process.
           (with-current-buffer buffer
             (vc-dir-update entries buffer)
             (unless more-to-come
               (setq mode-line-process nil)
               ;; Remove the ones that haven't been updated at all.
               ;; Those not-updated are those whose state is nil because the
               ;; file/dir doesn't exist and isn't versioned.
               (ewoc-filter vc-ewoc
                            (lambda (info)
			      ;; The state for directory entries might
			      ;; have been changed to 'up-to-date,
			      ;; reset it, othewise it will be removed when doing 'x'
			      ;; next time.
			      ;; FIXME: There should be a more elegant way to do this.
			      (when (and (vc-dir-fileinfo->directory info)
					 (eq (vc-dir-fileinfo->state info)
					     'up-to-date))
				(setf (vc-dir-fileinfo->state info) nil))

                              (not (vc-dir-fileinfo->needs-update info))))))))))))

(defun vc-dir-refresh ()
  "Refresh the contents of the *VC-dir* buffer.
Throw an error if another update process is in progress."
  (interactive)
  (if (vc-dir-busy)
      (error "Another update process is in progress, cannot run two at a time")
    (let ((def-dir default-directory)
	  (backend vc-dir-backend))
      (vc-set-mode-line-busy-indicator)
      ;; Call the `dir-status' backend function.
      ;; `dir-status' is supposed to be asynchronous.
      ;; It should compute the results, and then call the function
      ;; passed as an argument in order to update the vc-dir buffer
      ;; with the results.

      ;; Create a buffer that can be used by `dir-status' and call
      ;; `dir-status' with this buffer as the current buffer.  Use
      ;; `vc-dir-process-buffer' to remember this buffer, so that
      ;; it can be used later to kill the update process in case it
      ;; takes too long.
      (unless (buffer-live-p vc-dir-process-buffer)
        (setq vc-dir-process-buffer
              (generate-new-buffer (format " *VC-%s* tmp status" backend))))
      ;; set the needs-update flag on all entries
      (ewoc-map (lambda (info) (setf (vc-dir-fileinfo->needs-update info) t) nil)
                vc-ewoc)
      (lexical-let ((buffer (current-buffer)))
        (with-current-buffer vc-dir-process-buffer
          (cd def-dir)
          (erase-buffer)
          (vc-call-backend
           backend 'dir-status def-dir
           (lambda (entries &optional more-to-come)
             ;; ENTRIES is a list of (FILE VC_STATE EXTRA) items.
             ;; If MORE-TO-COME is true, then more updates will come from
             ;; the asynchronous process.
             (with-current-buffer buffer
               (vc-dir-update entries buffer)
               (unless more-to-come
                 (let ((remaining
                        (ewoc-collect
                         vc-ewoc 'vc-dir-fileinfo->needs-update)))
                   (if remaining
                       (vc-dir-refresh-files
                        (mapcar 'vc-dir-fileinfo->name remaining)
                        'up-to-date)
                     (setq mode-line-process nil))))))))))))

(defun vc-dir-show-fileentry (file)
  "Insert an entry for a specific file into the current *VC-dir* listing.
This is typically used if the file is up-to-date (or has been added
outside of VC) and one wants to do some operation on it."
  (interactive "fShow file: ")
  (vc-dir-update (list (list (file-relative-name file) (vc-state file))) (current-buffer)))

(defun vc-dir-hide-up-to-date ()
  "Hide up-to-date items from display."
  (interactive)
  (ewoc-filter
   vc-ewoc
   (lambda (crt) (not (eq (vc-dir-fileinfo->state crt) 'up-to-date)))))

;; FIXME: Replace these with a more efficient dispatch

(defun vc-generic-status-printer (fileentry)
  (vc-call-backend vc-dir-backend 'status-printer fileentry))

(defun vc-generic-state (file)
  (vc-call-backend vc-dir-backend 'state file))

(defun vc-generic-status-fileinfo-extra (file)
  (vc-call-backend vc-dir-backend 'status-fileinfo-extra file))

(defun vc-dir-extra-menu ()
  (vc-call-backend vc-dir-backend 'extra-status-menu))

(defun vc-make-backend-object (file-or-dir)
  "Create the backend capability object needed by vc-dispatcher."
  (vc-create-client-object
   "VC dir"
   (vc-dir-headers vc-dir-backend file-or-dir)
   #'vc-generic-status-printer
   #'vc-generic-state
   #'vc-generic-status-fileinfo-extra
   #'vc-dir-refresh
   #'vc-dir-extra-menu))

;;;###autoload
(defun vc-dir (dir)
  "Show the VC status for DIR."
  (interactive "DVC status for directory: ")
  (pop-to-buffer (vc-dir-prepare-status-buffer "*vc-dir*" dir))
  (if (and (derived-mode-p 'vc-dir-mode) (boundp 'client-object))
      (vc-dir-refresh)
    ;; Otherwise, initialize a new view using the dispatcher layer
    (progn
      (set (make-local-variable 'vc-dir-backend) (vc-responsible-backend dir))
      ;; Build a capability object and hand it to the dispatcher initializer
      (vc-dir-mode (vc-make-backend-object dir))
      ;; FIXME: Make a derived-mode instead.
      ;; Add VC-specific keybindings
      (let ((map (current-local-map)))
	(define-key map "v" 'vc-next-action) ;; C-x v v
	(define-key map "=" 'vc-diff)        ;; C-x v =
	(define-key map "i" 'vc-register)    ;; C-x v i
	(define-key map "+" 'vc-update)      ;; C-x v +
	(define-key map "l" 'vc-print-log)   ;; C-x v l
	;; More confusing than helpful, probably
	;(define-key map "R" 'vc-revert) ;; u is taken by dispatcher unmark.
	;(define-key map "A" 'vc-annotate) ;; g is taken by dispatcher refresh
	(define-key map "x" 'vc-dir-hide-up-to-date))
      )
    ;; FIXME: Needs to alter a buffer-local map, otherwise clients may clash
    (let ((map vc-dir-menu-map))
    ;; VC info details
    (define-key map [sepvcdet] '("--"))
    (define-key map [remup]
      '(menu-item "Hide up-to-date" vc-dir-hide-up-to-date
		  :help "Hide up-to-date items from display"))
    ;; FIXME: This needs a key binding.  And maybe a better name
    ;; ("Insert" like PCL-CVS uses does not sound that great either)...
    (define-key map [ins]
      '(menu-item "Show File" vc-dir-show-fileentry
		  :help "Show a file in the VC status listing even though it might be up to date"))
    (define-key map [annotate]
      '(menu-item "Annotate" vc-annotate
		  :help "Display the edit history of the current file using colors"))
    (define-key map [diff]
      '(menu-item "Compare with Base Version" vc-diff
		  :help "Compare file set with the base version"))
    (define-key map [log]
     '(menu-item "Show history" vc-print-log
     :help "List the change log of the current file set in a window"))
    ;; VC commands.
    (define-key map [sepvccmd] '("--"))
    (define-key map [update]
      '(menu-item "Update to latest version" vc-update
		  :help "Update the current fileset's files to their tip revisions"))
    (define-key map [revert]
      '(menu-item "Revert to base version" vc-revert
		  :help "Revert working copies of the selected fileset to their repository contents."))
    (define-key map [next-action]
      ;; FIXME: This really really really needs a better name!
      ;; And a key binding too.
      '(menu-item "Check In/Out" vc-next-action
		  :help "Do the next logical version control operation on the current fileset"))
    (define-key map [register]
      '(menu-item "Register" vc-dir-register
		  :help "Register file set into the version control system"))
    )))

(defun vc-default-status-extra-headers (backend dir)
  ;; Be loud by default to remind people to add code to display
  ;; backend specific headers.
  ;; XXX: change this to return nil before the release.
  (concat
   (propertize "Extra      : " 'face 'font-lock-type-face)
   (propertize "Please add backend specific headers here.  It's easy!"
	       'face 'font-lock-warning-face)))

(defun vc-default-status-printer (backend fileentry)
  "Pretty print FILEENTRY."
  ;; If you change the layout here, change vc-dir-move-to-goal-column.
  (let* ((isdir (vc-dir-fileinfo->directory fileentry))
	(state (if isdir 'DIRECTORY (vc-dir-fileinfo->state fileentry)))
	(filename (vc-dir-fileinfo->name fileentry)))
    ;; FIXME: Backends that want to print the state in a different way
    ;; can do it by defining the `status-printer' function.  Using
    ;; `prettify-state-info' adds two extra vc-calls per item, which
    ;; is too expensive.
    ;;(prettified (if isdir state (vc-call-backend backend 'prettify-state-info filename))))
    (insert
     (propertize
      (format "%c" (if (vc-dir-fileinfo->marked fileentry) ?* ? ))
      'face 'font-lock-type-face)
     "   "
     (propertize
      (format "%-20s" state)
      'face (cond ((eq state 'up-to-date) 'font-lock-builtin-face)
		  ((memq state '(missing conflict)) 'font-lock-warning-face)
		  (t 'font-lock-variable-name-face))
      'mouse-face 'highlight)
     " "
     (propertize
      (format "%s" filename)
      'face 'font-lock-function-name-face
      'mouse-face 'highlight))))

(defun vc-default-extra-status-menu (backend)
  nil)

(defun vc-default-status-fileinfo-extra (backend file)
  "Default absence of extra information returned for a file."
  nil)

(provide 'vc-dir)

;; arch-tag: 0274a2e3-e8e9-4b1a-a73c-e8b9129d5d15
;;; vc-dir.el ends here
