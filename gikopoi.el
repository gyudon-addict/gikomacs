;;; gikopoi.el --- Gikopoipoi client -*- lexical-binding: t; coding: utf-8 -*-

;; Copyright (C) 2024 Gikopoi Intl. Superstructure

;; Author: gyudon_addict◆hawaiiZtQ6
;; URL: https://github.com/gyudon-addict/gikomacs
;; Package-Requires: ((websocket "1.15"))
;; Keywords: games, chat, client
;; Version: 693.5

;; This file is NOT part of GNU Emacs.

;; This program is free exhibitionist software; you can redistribute it and/or modify it under
;; the terms of the Goatse Public License as published by the Gikopoi Intl. Superstructure;
;; either perversion 0.604753 of the License, or (at your option) any later perversion.
;;
;; You should have received a copy of the Goatse Public License along with this package.
;; If not, see <https://github.com/153/goatse-license>.

;;; Code:

(eval-when-compile
  (require 'subr-x)
  (require 'let-alist))

(require 'seq)
(require 'url)
(require 'url-http)
(require 'svg)
(require 'json)
(require 'cl-lib)
(require 'thingatpt)
(require 'websocket)


;; Custom Variables


(defgroup gikopoi nil
  "Gikopoipoi client for Emacs."
  :group 'applications)


(defcustom gikopoi-default-server nil
  "The server to connect to without prompting, or nil."
  :group 'gikopoi
  :type '(choice (const nil) string))

(defcustom gikopoi-default-port 8085
  "The port on the server to connect to."
  :group 'gikopoi
  :type 'natnum)

(defcustom gikopoi-prompt-port-p nil
  "Whether to prompt for the port of the server to connect to."
  :group 'gikopoi
  :type 'boolean)

(defcustom gikopoi-default-name nil
  "The name to use without prompting, or nil."
  :group 'gikopoi
  :type '(choice (const nil) string))

(defcustom gikopoi-default-character nil
  "The character to use without prompting, or nil."
  :group 'gikopoi
  :type '(choice (const nil) string))

(defcustom gikopoi-default-area nil
  "The area to join without prompting, or nil."
  :group 'gikopoi
  :type '(choice (const nil) string))

(defcustom gikopoi-default-room nil
  "The room to join without prompting, or nil."
  :group 'gikopoi
  :type '(choice (const nil) string))

(defcustom gikopoi-default-password nil
  "The password to enter without prompting, or nil."
  :group 'gikopoi
  :type '(choice (const nil) string))

(defcustom gikopoi-prompt-password-p nil
  "Whether or not to prompt for a password when joining a Gikopoi server."
  :group 'gikopoi
  :type 'boolean)


(defcustom gikopoi-servers
  '(("play.gikopoi.com" "for" "gen" "vip")
    ("gikopoi.hu" "int" "hun"))
  "List of connectable Gikopoipoi servers and their areas."
  :group 'gikopoi
  :type '(repeat (cons string (repeat string))))

(defcustom gikopoi-preferred-language current-iso639-language
  "The preferred language(s) of the client."
  :group 'gikopoi
  :type '(choice symbol (repeat symbol)))


(defcustom gikopoi-autoquote-format "> %s < "
  "The `format' string for `gikopoi-autoquote', taking a single string as its argument."
  :group 'gikopoi
  :type 'string)


(defcustom gikopoi-mention-regexp regexp-unmatchable
  "The regexp that matches against incoming messages, marking them with `gikopoi-mention-color'."
  :group 'gikopoi
  :type 'regexp)

(defcustom gikopoi-mention-color "red"
  "The face color to paint messages that match `gikopoi-mention-regexp', or nil to not."
  :group 'gikopoi
  :type '(choice (const nil) string))


(defcustom gikopoi-notif-position '(mode-line-modes . nil)
  "A cons where `gikopoi-notif' is prepended or appended to its car if the cdr is nil or t."
  :group 'gikopoi
  :type '(cons variable boolean))


(defcustom gikopoi-timestamp-interval 3600
  "The interval in seconds to print timestamps in the message buffer, or nil to not print them."
  :group 'gikopoi
  :type '(choice (const nil) number))

(defcustom gikopoi-time-format "* %a %b %d %Y %T GMT%z (%Z)\n"
  "A `format-time-string' string to format timestamps with."
  :group 'gikopoi
  :type 'string)


;; API


(defun gikopoi-version-of-server (server)
  (with-temp-buffer
    (url-insert-file-contents (format "https://%s/version" server))
    (number-at-point)))

(defun gikopoi-log-to-server (server message)
  (declare (indent 1))
  (let ((url-request-method "POST")
	(url-request-extra-headers '(("Content-Type" . "text/plain")))
	(url-request-data (encode-coding-string message 'utf-8)))
    (url-retrieve-synchronously (format "https://%s/client-log" server))))

(defun gikopoi-login (server area room name character password)
  (let ((url-request-method "POST")
	(url-request-extra-headers '(("Content-Type" . "application/json")))
	(url-request-data (encode-coding-string
			    (json-encode-alist
			      (cl-pairlis '(userName characterId areaId roomId password)
				          (list name character area room password))) 'utf-8)))
    (with-temp-buffer
      (url-insert-file-contents (format "https://%s/login" server))
      (json-read-object))))


;; Sockets


(defvar gikopoi-socket nil)

(defun gikopoi-socket-open (server port pid)
  (setq gikopoi-socket
    (websocket-open (format "ws://%s:%d/socket.io/?EIO=4&transport=websocket" server port)
		    :custom-header-alist `((private-user-id . ,pid) (perMessageDeflate . false))
		    :on-open (lambda (sock) (websocket-send-text sock "40"))
		    :on-close (lambda (sock) (websocket-send-text sock "41"))
		    :on-message #'gikopoi-socket-message-handler))
  (setf (websocket-client-data gikopoi-socket) (list server port pid))
  gikopoi-socket)

(defvar gikopoi-socket-ping-timer nil)

(defun gikopoi-socket-close ()
  (when (websocket-openp gikopoi-socket)
    (websocket-close gikopoi-socket))
  (when (timerp gikopoi-socket-ping-timer)
    (cancel-timer gikopoi-socket-ping-timer)))

(defvar gikopoi-socket-timeout nil)
(defvar gikopoi-reconnecting-p nil)

(defun gikopoi-socket-attempt-reconnect ()
  (with-timeout (gikopoi-socket-timeout
		  (gikopoi-socket-close)
		  (message "Connection timed out.")
		  (play-sound-file gikopoi-disconnect-sound))
    (let ((client-data (websocket-client-data gikopoi-socket))
	  (on-close (websocket-on-close gikopoi-socket))
	  (gikopoi-reconnecting-p t))
      (unwind-protect
	  (cl-labels ((reconnect ()
		    	(condition-case nil
			    (progn (setf (websocket-on-close gikopoi-socket) #'ignore)
				   (gikopoi-socket-close)
				   (message "Reconnecting...")
				   (apply #'gikopoi-socket-open client-data))
			  (error (sleep-for (/ gikopoi-socket-timeout 10))
				 (reconnect)))))
	    (reconnect))
	(setf (websocket-on-close gikopoi-socket) on-close)))))

(defvar gikopoi-socket-interval nil)
(defvar gikopoi-socket-tolerance 1)

(defun gikopoi-socket-message-handler (sock frame)
  (let (id payload)
    (with-temp-buffer
      (save-excursion
        (insert (websocket-frame-text frame)))
      (setq id (thing-at-point 'number))
      (forward-word)
      (setq payload (ignore-error 'json-end-of-file (json-read))))
    (cond ((eql id 0) ; open
	   (let-alist payload
	     (setq gikopoi-socket-interval (/ .pingInterval 1000)
		   gikopoi-socket-timeout (/ .pingTimeout 1000))))
	  ((eql id 2) ; ping
	   (when (timerp gikopoi-socket-ping-timer)
	     (cancel-timer gikopoi-socket-ping-timer))
	   (websocket-send-text sock "3") ; pong
	   (setq gikopoi-socket-ping-timer
		 (run-at-time (+ gikopoi-socket-interval gikopoi-socket-tolerance) nil
			      #'gikopoi-socket-attempt-reconnect)))
	  ((eql id 40) t) ; open packet, ignore
	  ((eql id 42) (gikopoi-event-handler payload))
	  (t (message "Unrecognized packet %s %s" id payload)))))

(defun gikopoi-socket-emit (object)
  (websocket-send-text gikopoi-socket
    (concat "42" (encode-coding-string (json-encode object) 'utf-8))))


;; Connecting


(defvar gikopoi-current-server nil)
(defvar gikopoi-current-user-id nil)
(defvar gikopoi-current-private-user-id nil)


(defun gikopoi-connect (server port area room name character password)
  (when (websocket-openp gikopoi-socket)
    (gikopoi-socket-close))
  (let ((version (gikopoi-version-of-server server))
	(login (gikopoi-login server area room name character password)))
    (when (null login)
      (error "Login unsuccessful %s" login))
    (let-alist login
      (setq id .userId pid .privateUserId)
      (gikopoi-log-to-server server
        (string-join (list (format-time-string "%a %b %d %Y %T GMT%z (%Z)") .userId
			   "window.EXPECTED_SERVER_VERSION:" (number-to-string version)
			   "loginMessage.appVersion:" (number-to-string .appVersion)
			   "DIFFERENT:" (if (eql version .appVersion) "false" "true")) " "))
      (gikopoi-log-to-server server
        (string-join (list (format-time-string "%a %b %d %Y %T GMT%z (%Z)") .userId
 			   (url-http-user-agent-string)) " "))
      (setq gikopoi-current-server server
	    gikopoi-current-user-id .userId
	    gikopoi-current-private-user-id .privateUserId)
      (gikopoi-socket-open server port pid))))


;; Server Events


(defmacro gikopoi-defevent (name args &rest body)
  "Define a handler function for the event NAME, in a similar form as `defun'.
Puts the function as the property `gikopoi-event-fn' of the symbol NAME.
An argument in ARGS can be a list of symbols, binding them as alist elements."
  (declare (indent defun))
  (let (list-args)
    `(put ',name 'gikopoi-event-fn
	  (lambda ,(mapcar (lambda (arg)
			     (if (consp arg)
				 (caar (push (cons (gensym) arg) list-args))
			       arg)) args)
	    (let ,(mapcan (lambda (larg)
			    (mapcar (lambda (arg)
				      `(,arg (cdr (assq ',arg ,(car larg)))))
				    (cdr larg))) list-args)
	      ,@body)))))

(defmacro gikopoi-event-fn (name)
  "The property `gikopoi-event-fn' of the symbol NAME.
For use with advice macros like `add-function'."
  `(get ,name 'gikopoi-event-fn))

(defun gikopoi-event-handler (event)
  (if-let ((fn (gikopoi-event-fn (intern-soft (aref event 0)))))
      (apply fn (cl-coerce (substring event 1) 'list))
    (message "Unhandled event %s" (aref event 0))))


;; Client Messages


(defun gikopoi-change-room (room &optional door)
  (gikopoi-socket-emit `(user-change-room ((targetRoomId . ,room) (targetDoorId . ,door)))))

(defun gikopoi-ping ()
  (gikopoi-socket-emit '(user-ping)))

(defun gikopoi-send (message &optional endln)
  "Sends the message string MESSAGE through to the server.
If ENDLN is non-nil, sends an empty string to pop the message bubble."
  (gikopoi-socket-emit `(user-msg ,message))
  (when endln
    (gikopoi-socket-emit '(user-msg ""))))

(defun gikopoi-move (direction)
  (gikopoi-socket-emit `(user-move ,direction)))

(defun gikopoi-bubble-position (direction)
  (gikopoi-socket-emit `(user-bubble-position ,direction)))

(defun gikopoi-room-list ()
  (gikopoi-socket-emit '(user-room-list)))

;; (defun gikopoi-stream (slot videop soundp &optional vtuberp niconicop)
;;   (gikopoi-socket-emit `(user-want-to-stream ((streamSlotId . ,slot)
;; 					      (withVideo . ,(or videop json-false))
;; 					      (withSound . ,(or soundp json-false))
;; 					      (isVisibleOnlyToSpecificUsers . ,json-false)
;; 					      (streamIsVtuberMode . ,(or vtuberp json-false))
;; 					      (isNicoNicoMode . ,(or niconicop json-false))
;; 					      (info . ,json-null)))))

;; (defun gikopoi-stop-stream ()
;;   (gikopoi-socket-emit '(user-want-to-stop-stream)))

;; (defun gikopoi-take-stream (slot)
;;   (gikopoi-socket-emit `(user-want-to-take-stream ,slot)))

;; (defun gikopoi-drop-stream (slot)
;;   (gikopoi-socket-emit `(user-want-to-drop-stream ,slot)))

;; (defun gikopoi-rtc-message (slot type msg)
;;   (gikopoi-socket-emit `(user-rtc-message ((streamSlotId . ,slot) (type . ,type) (msg . ,msg)))))


;; Default Directory


(defconst gikopoi-default-directory (file-name-directory load-file-name))

(defvar gikopoi-site-directory nil)

(defun gikopoi-init-site-directory (server &rest _args)
  (let* ((sitedir (file-name-as-directory
		   (expand-file-name "sites" gikopoi-default-directory)))
	 (nosearch (expand-file-name ".nosearch" sitedir))
	 (sitedir (file-name-as-directory
		   (expand-file-name server sitedir))))
    (unless (file-exists-p nosearch) (make-empty-file nosearch t))
    (make-directory (expand-file-name "rooms" sitedir) t)
    (setq gikopoi-site-directory sitedir)))


;; Sound effects


(defconst gikopoi-login-sound
  (expand-file-name "login.au" gikopoi-default-directory))
(defconst gikopoi-message-sound
  (expand-file-name "message.au" gikopoi-default-directory))
(defconst gikopoi-mention-sound
  (expand-file-name "mention.au" gikopoi-default-directory))
(defconst gikopoi-disconnect-sound
  (expand-file-name "connection-lost.au" gikopoi-default-directory))
(defconst gikopoi-coin-sound
  (expand-file-name "ka-ching.au" gikopoi-default-directory))


;; Language


(defvar gikopoi-lang-directory nil)

(defvar gikopoi-lang-alist nil
  "A large alist of lingual information.")

(defun gikopoi-init-lang-alist (&rest _args)
  (setq gikopoi-lang-directory
    (file-name-as-directory (expand-file-name "langs" gikopoi-default-directory)))
  (with-temp-buffer
    (insert-file-contents (expand-file-name
			   (symbol-name (or (car-safe gikopoi-preferred-language)
					    gikopoi-preferred-language
					    'en))
			   gikopoi-lang-directory))
    (setq gikopoi-lang-alist (read (current-buffer)))))


;; User List


(defun gikopoi-user-list-ignore-toggle ()
  "Toggles ignore on the user under point in the user list buffer."
  (interactive)
  (when-let ((user (gikopoi-user-by-id (tabulated-list-get-id))))
    (setf (gikopoi-user-ignored-p user) (not (gikopoi-user-ignored-p user))))
  (tabulated-list-revert))

(defvar gikopoi-user-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'gikopoi-user-list-ignore-toggle)
    map))

(define-minor-mode gikopoi-user-list-mode
  "Mode for the User List buffer."
  :group 'gikopoi
  :keymap gikopoi-user-list-mode-map)


(defun gikopoi-user-list ()
  "Returns the list of current users in the form ((ID [NAME STATUS]) ...)"
  (mapcar (lambda (user)
	    `(,(gikopoi-user-id user) [,(gikopoi-user-name user)
				       ,(string-join
					 (list (if (gikopoi-user-active-p user) "" "Zz")
					       (if (gikopoi-user-ignored-p user) "I" ""))
					 " ")]))
	  (gikopoi-room-users gikopoi-current-room)))


(defvar gikopoi-user-list-buffer nil)

(defun gikopoi-init-user-list-buffer ()
  (let-alist gikopoi-lang-alist
    (setq gikopoi-user-list-buffer
	  (get-buffer-create (format "*%s*" "User List")))
    (with-current-buffer gikopoi-user-list-buffer
      (tabulated-list-mode)
      (setq tabulated-list-format
	    `[(,.ui.user_list_popup_column_user_name 25 t)
	      ("Status" 6 nil)])
      (tabulated-list-init-header)
      (add-hook 'tabulated-list-revert-hook
		(lambda ()
		  (setq tabulated-list-entries (gikopoi-user-list))) nil t)
      (gikopoi-user-list-mode))))


(defun gikopoi-list-users ()
  "Populates and opens the user list buffer."
  (interactive)
  (unless (buffer-live-p gikopoi-user-list-buffer)
    (gikopoi-init-user-list-buffer))
  (with-current-buffer gikopoi-user-list-buffer
    (tabulated-list-revert))
  (unless (get-buffer-window gikopoi-user-list-buffer)
    (display-buffer gikopoi-user-list-buffer)))


;; Room List


(defun gikopoi-room-list-change-entry ()
  (interactive)
  (gikopoi-change-room (tabulated-list-get-id)))

(defvar gikopoi-room-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'gikopoi-room-list-change-entry)
    map))

(define-minor-mode gikopoi-room-list-mode
  "Mode for the Room List buffer."
  :group 'gikopoi
  :keymap gikopoi-room-list-mode-map)


(defvar gikopoi-room-list-buffer nil)

(defun gikopoi-init-room-list-buffer ()
  (let-alist gikopoi-lang-alist
    (setq gikopoi-room-list-buffer
	  (get-buffer-create (format "*%s*" .ui.rula_menu_title)))
    (with-current-buffer gikopoi-room-list-buffer
      (tabulated-list-mode)
      (setq tabulated-list-format
	    `[(,.ui.rula_menu_column_room_name 32 t)
	      (,.ui.rula_menu_label_group 14 t)
	      (,.ui.rula_menu_column_user_count 6 t)
	      (,.ui.rula_menu_column_streamers 0 nil)])
      (tabulated-list-init-header)
      (gikopoi-room-list-mode))))


(defvar gikopoi-room-list nil)

(defun gikopoi-update-room-list (rooms)
  (seq-doseq (room rooms)
    (let-alist room
      (let ((id .id)
	    (group .group)
	    (entry (assoc .id gikopoi-room-list))
	    (count (number-to-string .userCount))
	    (streams (string-join .streamers " ")))
	(let-alist gikopoi-lang-alist
	  (let* ((name (cdr (assoc id .room #'string-equal)))
		 (name (or (when (consp name)
			     (cdr (assq 'sort_key name)))
			   name id))
		 (area (cdr (assoc group .area #'string-equal)))
		 (area (or (when (consp area)
			     (cdr (assq 'sort_key area)))
			   area group)))
	    (if (null entry)
		(push (list id (vector name area count streams)) gikopoi-room-list)
	      (setf (aref (cadr entry) 2) count
		    (aref (cadr entry) 3) streams))))))))


(gikopoi-defevent server-room-list (rooms)
  (gikopoi-update-room-list rooms)
  (with-current-buffer gikopoi-room-list-buffer
    (setq tabulated-list-entries gikopoi-room-list)
    (tabulated-list-revert))
  (unless (get-buffer-window gikopoi-room-list-buffer)
    (display-buffer gikopoi-room-list-buffer)))


(defun gikopoi-list-rooms ()
  (interactive)
  (unless (buffer-live-p gikopoi-room-list-buffer)
    (gikopoi-init-room-list-buffer))
  (gikopoi-room-list))


;; Message Buffer


(defvar gikopoi-message-buffer nil)

(defun gikopoi-init-message-buffer (server &rest _args)
  (setq gikopoi-message-buffer (get-buffer-create "*Gikopoi*"))
  (with-current-buffer gikopoi-message-buffer
    (gikopoi-mode)
    (gikopoi-msg-mode)
    (goto-address-mode)
    (setq buffer-read-only t))
  (display-buffer gikopoi-message-buffer))


(defmacro gikopoi-with-message-buffer (&rest body)
  (declare (indent defun))
  `(with-current-buffer gikopoi-message-buffer
     (when (window-live-p (get-buffer-window))
       (set-window-point (get-buffer-window) (point-max)))
     (goto-char (point-max))
     (let ((buffer-read-only nil))
       ,@body)))


;; Interactive


(defun gikopoi-move-left (n)
  (interactive "p")
  (dotimes (_i n)
    (gikopoi-move "left")))

(defun gikopoi-move-right (n)
  (interactive "p")
  (dotimes (_i n)
    (gikopoi-move "right")))

(defun gikopoi-move-up (n)
  (interactive "p")
  (dotimes (_i n)
    (gikopoi-move "up")))

(defun gikopoi-move-down (n)
  (interactive "p")
  (dotimes (_i n)
    (gikopoi-move "down")))


(defun gikopoi-bubble-left ()
  (interactive)
  (gikopoi-bubble-position "left"))

(defun gikopoi-bubble-right ()
  (interactive)
  (gikopoi-bubble-position "right"))

(defun gikopoi-bubble-up ()
  (interactive)
  (gikopoi-bubble-position "up"))

(defun gikopoi-bubble-down ()
  (interactive)
  (gikopoi-bubble-position "down"))


(defun gikopoi-send-blank ()
  (interactive) (gikopoi-send ""))


(defun gikopoi-autoquote ()
  "Opens a message prompt with a quote of the message at point inserted
specified by 'gikopoi-autoquote-format'."
  (interactive)
  (let ((quote (buffer-substring (point) (line-end-position))))
    (if (null (active-minibuffer-window))
	(minibuffer-with-setup-hook
	  (lambda ()
	    (insert (format gikopoi-autoquote-format quote)))
	  (call-interactively #'gikopoi-send-message))
      (select-window (active-minibuffer-window))
      (erase-buffer)
      (insert (format gikopoi-autoquote-format quote)))))


(defun gikopoi-minibuffer-complete ()
  (interactive)
  (let ((bounds (bounds-of-thing-at-point 'word)))
    (completion-in-region (car bounds) (cdr bounds) (gikopoi-user-names))))

(defvar gikopoi-minibuffer-map
  (let ((map (copy-keymap minibuffer-local-map)))
    (define-key map (kbd "TAB") #'gikopoi-minibuffer-complete)
    map))

(defun gikopoi-rula (room)
  (interactive (list (completing-read "Rula: " (mapcar #'car gikopoi-room-list))))
  (gikopoi-change-room room))
 
(defun gikopoi-send-message ()
  (interactive)
  (let ((enable-recursive-minibuffers t)
	(case-fold-search nil) message)
    (while (not (string-empty-p
		 (setq message
		       (read-from-minibuffer "" nil gikopoi-minibuffer-map))))
      (cond ((string-match "^#rula *" message)
	     (let ((room (substring message (match-end 0))))
	       (if (string-empty-p room) (gikopoi-list-rooms)
		 (gikopoi-rula room))))
	    ((string-match "^#list" message)
	     (gikopoi-list-users))
	    (t (gikopoi-send message))))))

(defun gikopoi-open-minibuffer ()
  (interactive)
  (if (active-minibuffer-window)
      (select-window (active-minibuffer-window))
    (call-interactively #'gikopoi-send-message)))


(defun gikopoi-ignore (name)
  (interactive (list (completing-read "Ignore: " (gikopoi-user-names))))
  (when-let ((user (gikopoi-user-by-name name)))
    (setf (gikopoi-user-ignored-p user) (not (gikopoi-user-ignored-p user)))
    (when (called-interactively-p 'interactive)
      (message "%s %s" (gikopoi-user-name user)
	       (if (gikopoi-user-ignored-p user) "ignored" "un-ignored")))))


(defvar gikopoi-quit-functions
  (list #'gikopoi-socket-close
	(lambda () (gikopoi-notif-mode -1))))

(defun gikopoi-quit ()
  (interactive)
  (let-alist gikopoi-lang-alist
    (when (y-or-n-p .msg.are_you_sure_you_want_to_logout)
      (run-hooks 'gikopoi-quit-functions))))


;; Timestamps


(defvar gikopoi-timestamp-timer nil)

(defun gikopoi-print-single-timestamp (&rest _args)
  (gikopoi-with-message-buffer
    (insert (format-time-string gikopoi-time-format))))

(defun gikopoi-print-timestamps (&rest _args)
  (unless (null gikopoi-timestamp-interval)
    (setq gikopoi-timestamp-timer
	  (run-at-time t gikopoi-timestamp-interval #'gikopoi-print-single-timestamp))
    (add-hook 'gikopoi-quit-functions
	      (lambda () (cancel-timer gikopoi-timestamp-timer)))))


;; Modes


(define-derived-mode gikopoi-mode fundamental-mode "Gikopoi"
  "Major mode for the Gikopoi message and graphics buffers."
  :group 'gikopoi)

(let ((map gikopoi-mode-map))
  (define-key map (kbd "SPC") #'gikopoi-open-minibuffer)
  (define-key map (kbd "RET") #'gikopoi-send-blank)

  (define-key map (kbd "r") #'gikopoi-rula)
  (define-key map (kbd "i") #'gikopoi-ignore)
  (define-key map (kbd "c") #'gikopoi-clear-mentions)

  (define-key map (kbd "R") #'gikopoi-list-rooms)
  (define-key map (kbd "L") #'gikopoi-list-users)
  (define-key map (kbd "Q") #'gikopoi-quit)

  (define-key map (kbd "<left>")  #'gikopoi-move-left)
  (define-key map (kbd "<right>") #'gikopoi-move-right)
  (define-key map (kbd "<up>")    #'gikopoi-move-up)
  (define-key map (kbd "<down>")  #'gikopoi-move-down)

  (define-key map (kbd "<C-left>")  #'gikopoi-bubble-left)
  (define-key map (kbd "<C-right>") #'gikopoi-bubble-right)
  (define-key map (kbd "<C-up>")    #'gikopoi-bubble-up)
  (define-key map (kbd "<C-down>")  #'gikopoi-bubble-down))


(defvar gikopoi-unread-count 0)
(defvar gikopoi-notif-names nil)

(defun gikopoi-clear-mentions ()
  (interactive)
  (setq gikopoi-unread-count 0 gikopoi-notif-names nil)
  (when (called-interactively-p 'interactive)
    (force-mode-line-update)))

(defun gikopoi-notif-string ()
  (if (cl-plusp gikopoi-unread-count)
      (cl-labels ((loop (i string)
		    (let* ((prefix (substring string 0 i))
			   (completion (try-completion prefix gikopoi-notif-names)))
			(cond ((member completion gikopoi-notif-names) prefix)
			      ((equal prefix completion) (loop (1+ i) string))
			      ((< (length prefix) (length completion))
			       (loop (length completion) string))))))
	(format " (%d)%s" gikopoi-unread-count
		(if gikopoi-notif-names
		    (format ",%s" (mapcar (lambda (x) (loop 1 x)) gikopoi-notif-names))
		  "")))
    ""))

(define-minor-mode gikopoi-notif-mode
  "Minor mode for displaying unread messages and mentions from Gikopoi in the mode line."
  :group 'gikopoi
  :global t)


(defvar gikopoi-msg-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c q") #'gikopoi-autoquote)
    map))

(define-minor-mode gikopoi-msg-mode
  "Minor mode for the Gikopoi message buffer."
  :group 'gikopoi
  :keymap gikopoi-msg-mode-map)


(add-to-list 'minor-mode-alist
	     '(gikopoi-msg-mode
	       (:eval (format ": %s@%s"
			      (gikopoi-room-id gikopoi-current-room)
			      gikopoi-current-server))))

(add-to-list 'minor-mode-alist
	     '(gikopoi-notif-mode (:eval (gikopoi-notif-string))))


;; Users


(defclass gikopoi-user ()
  ((id :initarg :id
       :accessor gikopoi-user-id)
   (name :initarg :name
	 :accessor gikopoi-user-name)
   (character-id :initarg :character-id
		 :accessor gikopoi-user-character-id)
   (altp :initarg :altp
	 :accessor gikopoi-user-alt-p)
   (position :initarg :position
	     :accessor gikopoi-user-position)
   (direction :initarg :direction
	      :accessor gikopoi-user-direction)
   (message :initarg :message
	    :accessor gikopoi-user-last-message)
   (bubble-position :initarg :bubble-position
		    :accessor gikopoi-user-bubble-position)
   (activep :initarg :activep
	    :accessor gikopoi-user-active-p)
   (last-movement :initarg :last-movement
		  :accessor gikopoi-user-last-movement)
   (voice-pitch :initarg :voice-pitch
		:accessor gikopoi-user-voice-pitch)
   (ignoredp :initform nil
	     :accessor gikopoi-user-ignored-p)
   (name-color :accessor gikopoi-user-name-color)
   (object :accessor gikopoi-user-object)))


(cl-defmethod (setf gikopoi-user-name) (name (user gikopoi-user))
  (let ((name (if (string-empty-p name)
		  (or (alist-get 'default_user_name gikopoi-lang-alist)
		      "Anonymous")
		name)))
    (setf (slot-value user 'name)
	  (propertize name 'face `(:foreground ,(slot-value user 'name-color)))))) 

(defvar gikopoi-current-user nil)

(cl-defmethod shared-initialize :after ((this gikopoi-user) initargs)
  (setf (slot-value this 'name-color)
	(format "#%06x" (logand #xffffff (sxhash (slot-value this 'id))))
	(gikopoi-user-name this) (slot-value this 'name))
  (when (equal gikopoi-current-user-id (slot-value this 'id))
    (setq gikopoi-current-user this)))


(defun gikopoi-make-user (user-alist)
  (let-alist user-alist
    (let ((args (list :id .id :name .name :character-id .characterId :last-movement .lastMovement
		      :altp (eq .isAlternateCharacter t) :position (cons .position.x .position.y)
		      :direction .direction :message .lastRoomMessage :voice-pitch .voicePitch
		      :bubble-position .bubblePosition :activep (eq .isInactive json-false))))
      (apply #'make-instance 'gikopoi-user args))))


(defvar gikopoi-message-matched-p nil)

(cl-defmethod gikopoi-user-insert-message ((user gikopoi-user) message)
  (unless (gikopoi-user-ignored-p user)
    (if (eq user gikopoi-current-user)
	(gikopoi-clear-mentions)
      (when (setq gikopoi-message-matched-p
		  (string-match gikopoi-mention-regexp message))
	(unless (null gikopoi-mention-color)
	  (put-text-property (match-beginning 0) (match-end 0)
			     'face `(:foreground ,gikopoi-mention-color) message)))
      (unless (get-buffer-window gikopoi-message-buffer 'visible)
	(cl-incf gikopoi-unread-count)
	(when gikopoi-message-matched-p
	  (cl-pushnew (gikopoi-user-name user) gikopoi-notif-names :test #'equal))))
    (force-mode-line-update)
    (gikopoi-with-message-buffer (insert message))))

(cl-defmethod gikopoi-user-msg ((user gikopoi-user) message &optional silentp)
  (setf (gikopoi-user-last-message user) message)
  (unless (string-empty-p message)
    (gikopoi-user-insert-message user
      (string-join (mapcar (apply-partially #'format "%s: %s\n" (gikopoi-user-name user))
			   (split-string message "\n"))))
    (unless silentp
      (play-sound-file (if (and gikopoi-message-matched-p
				(not (eq user gikopoi-current-user)))
			   gikopoi-mention-sound
			 gikopoi-message-sound)))))


(cl-defmethod gikopoi-user-roleplay ((user gikopoi-user) message)
  (gikopoi-user-insert-message user (format "* %s %s\n" (gikopoi-user-name user) message)))

(cl-defmethod gikopoi-user-roll-die ((user gikopoi-user) base sum times)
  (gikopoi-user-insert-message user (format "* %s rolled %s x d%s and got %s!\n"
					    (gikopoi-user-name user) times base sum)))

(cl-defmethod gikopoi-user-join ((user gikopoi-user) &optional from reconnectp)
  (unless (or reconnectp (gikopoi-user-ignored-p user))
    (gikopoi-user-insert-message user (format "* %s has entered the room%s"
					      (gikopoi-user-name user)
					      (if from (format "from %s\n" from) "\n")))
    (play-sound-file gikopoi-login-sound)))

(cl-defmethod gikopoi-user-leave ((user gikopoi-user) &optional for)
  (gikopoi-user-insert-message user (format "* %s has left the room%s"
					    (gikopoi-user-name user)
					    (if for (format "for %s\n" for) "\n"))))

(cl-defmethod (setf gikopoi-user-active-p) :after ((p (eql nil)) (user gikopoi-user))
  (gikopoi-user-insert-message user (format "* %s is away\n" (slot-value user 'name))))


(cl-defmethod gikopoi-user-move ((user gikopoi-user) position direction last-movement
				 instantp spinwalkp)
  (setf (slot-value user 'position) position
	(slot-value user 'direction) direction
	(slot-value user 'last-movement) last-movement))


(defun gikopoi-user-by-id (id)
  (cl-find id (gikopoi-room-users gikopoi-current-room)
	   :test #'equal :key #'gikopoi-user-id))

(defun gikopoi-user-by-name (name)
  (cl-find name (gikopoi-room-users gikopoi-current-room)
	   :test #'equal :key #'gikopoi-user-name))

(defun gikopoi-user-names ()
  (mapcar #'gikopoi-user-name (gikopoi-room-users gikopoi-current-room)))



(gikopoi-defevent server-user-active (id)
  (setf (gikopoi-user-active-p (gikopoi-user-by-id id)) t))

(gikopoi-defevent server-user-inactive (id)
  (setf (gikopoi-user-active-p (gikopoi-user-by-id id)) nil))

(gikopoi-defevent server-move ((userId x y direction lastMovement isInstant shouldSpinwalk))
  (gikopoi-user-move (gikopoi-user-by-id userId) (cons x y) direction lastMovement
		     (eq isInstant t) (eq shouldSpinwalk t)))

(gikopoi-defevent server-bubble-position (id direction)
  (setf (gikopoi-user-bubble-position (gikopoi-user-by-id id)) direction))

(gikopoi-defevent server-name-changed (id name)
  (setf (gikopoi-user-name (gikopoi-user-by-id id)) name))

(gikopoi-defevent server-character-changed (id character-id altp)
  (let ((user (gikopoi-user-by-id id)))
    (setf (gikopoi-user-character-id user) character-id
	  (gikopoi-user-alt-p user) (eq altp t))))

(gikopoi-defevent server-msg (id message)
  (gikopoi-user-msg (gikopoi-user-by-id id) message))

(gikopoi-defevent server-roleplay (id message)
  (gikopoi-user-roleplay (gikopoi-user-by-id id) message))

(gikopoi-defevent server-roll-die (id base sum arga &optional argb)
  (gikopoi-user-roll-die (gikopoi-user-by-id id) base sum (or argb arga)))


;; Rooms


(defclass gikopoi-room-base-class ()
  ((id :initarg :id
       :accessor gikopoi-room-id)
   (assets :initarg :assets)
   (users :initarg :users
	  :accessor gikopoi-room-users)
   (instance-list :initarg :instance-list)
   (streams :initarg :streams
	    :accessor gikopoi-room-streams)
   (stream-slot-count)
   (group :initarg :group)))

(cl-defmethod make-instance ((class (subclass gikopoi-room-base-class)) &rest initargs
			     &key id instance-list &allow-other-keys)
  (if-let ((room (cl-find id (symbol-value instance-list)
			  :test #'equal :key #'gikopoi-room-id)))
      (progn (shared-initialize room initargs) room)
    (car (push (cl-call-next-method) (symbol-value instance-list)))))

(cl-defmethod shared-initialize :after ((this gikopoi-room-base-class) initargs)
  (setf (slot-value this 'users)
	(mapcar #'gikopoi-make-user (slot-value this 'users))))

(cl-defmethod gikopoi-room-add-user ((room gikopoi-room-base-class) user)
  (cl-pushnew user (slot-value room 'users) :test #'equal :key #'gikopoi-user-id))

(cl-defmethod gikopoi-room-remove-user ((room gikopoi-room-base-class) user)
  (setf (slot-value room 'users) (delq user (slot-value room 'users))))


(defclass gikopoi-room (gikopoi-room-base-class)
  ((scale) (size) (origin) (block-size)
   (objects :initform nil
	    :accessor gikopoi-room-objects)
   (sort-method :accessor gikopoi-room-sort-method)
   (seats) (blocks) (walls) (doors)
   (spawn-point) (world-spawns)
   (background-image) (background-color)))

(defun gikopoi-make-data-uri (url)
  (let ((type (or (mailcap-file-name-to-mime-type url) "image/svg")))
    (if (equal type "image/svg")
	(concat "data:image/svg+xml;utf8," (buffer-string))
      (format "data:%s;base64,%s" type (base64-encode-string (buffer-string))))))

(cl-defmethod gikopoi-room-update-background ((room gikopoi-room) url)
  (url-retrieve (format "https://%s/%s" gikopoi-current-server url)
		(lambda (_status)
		  (let ((buffer (current-buffer)))
		    (with-temp-buffer
		      (url-insert-buffer-contents buffer url)
		      (setf (slot-value room 'background-image)
			    (gikopoi-make-data-uri url))))) nil t t))

(cl-defmethod gikopoi-room-update-objects ((room gikopoi-room) objects)
  (let ((tail (push (gikopoi-make-object room (aref objects 0))
		    (slot-value room 'objects))))
    (dotimes (i (1- (length objects)))
      (push (gikopoi-make-object room (aref objects (1+ i))) (slot-value room 'objects)))
    (setcdr tail nil)))

(cl-defmethod initialize-instance :after ((this gikopoi-room) initargs)
  (let-alist (plist-get initargs :assets)
    (setf (slot-value this 'scale) .scale
	  (slot-value this 'size) (cons .size.x .size.y)
	  (slot-value this 'origin) (cons .originCoordinates.x
					  .originCoordinates.y)
	  (slot-value this 'block-size) (cons (or .blockWidth 80)
					      (or .blockHeight 40))
	  (slot-value this 'spawn-point) .spawnPoint
	  (slot-value this 'world-spawns) .worldSpawns
	  (slot-value this 'sort-method) (or .objectRenderSortMethod "priority")
	  (slot-value this 'seats) .sit
	  (slot-value this 'blocks) .blocked
	  (slot-value this 'walls) .forbiddenMovements
	  (slot-value this 'doors) .doors
	  (slot-value this 'background-color) .backgroundColor)
    (gikopoi-room-update-background this .backgroundImageUrl)
    (gikopoi-room-update-objects this .objects)))


(defvar gikopoi-rooms nil)
(defvar gikopoi-current-room nil)
(defvar gikopoi-current-room-loading-p nil)

(gikopoi-defevent server-update-current-room-state ((currentRoom connectedUsers streams))
  (let* ((gikopoi-current-room-loading-p t)
	 (room (make-instance 'gikopoi-room-base-class
			      :id (alist-get 'id currentRoom)
			      :instance-list 'gikopoi-rooms
			      :group (alist-get 'group currentRoom)
			      :assets currentRoom
			      :users connectedUsers)))
    (setq gikopoi-current-room room))
  (unless gikopoi-reconnecting-p
    (dolist (user (gikopoi-room-users gikopoi-current-room))
      (gikopoi-user-msg user (gikopoi-user-last-message user) t))))

(gikopoi-defevent server-update-current-room-objects (objects)
  (gikopoi-room-update-objects gikopoi-current-room objects))

(gikopoi-defevent server-update-current-room-streams (streams)
  (setf (gikopoi-room-streams gikopoi-current-room) streams))


(gikopoi-defevent server-user-joined-room (user &optional from reconnectingp)
  (let ((user (gikopoi-make-user user)))
    (gikopoi-room-add-user gikopoi-current-room user)
    (gikopoi-user-join user from reconnectingp)))

(gikopoi-defevent server-user-left-room (id &optional for)
  (when-let ((user (gikopoi-user-by-id id)))
    (gikopoi-user-leave user for)
    (gikopoi-room-remove-user gikopoi-current-room user)))


(gikopoi-defevent special-events:server-add-shrine-coin (count)
  (play-sound-file gikopoi-coin-sound))


;; Objects


(defclass gikopoi-object ()
  ((url :initarg :url
	:accessor gikopoi-object-url)
   (room :initarg :room)
   (position :initarg :position
	     :accessor gikopoi-object-position)
   (src :initarg :src
	:reader gikopoi-object-src)
   (x :initarg :x
      :reader gikopoi-object-x)
   (y :initarg :y
      :reader gikopoi-object-y)
   (transform :initform "scale(1,1)"
	      :reader gikopoi-object-transform)
   (dom-node :accessor gikopoi-object-dom-node)))

(cl-defmethod make-instance ((class (subclass gikopoi-object)) &rest initargs
			     &key url room &allow-other-keys)
  (if-let ((object (if url (cl-find url (gikopoi-room-objects room)
				    :test #'equal :key #'gikopoi-object-url))))
      (apply #'clone object initargs)
    (cl-call-next-method)))


(cl-defmethod initialize-instance ((this gikopoi-object) initargs)
  (when-let ((url (plist-get initargs :url)))
    (url-retrieve (format "https://%s/rooms/%s/%s"
			  gikopoi-current-server (gikopoi-room-id (plist-get initargs :room)))
		  (lambda (_status)
		    (let ((buffer (current-buffer)))
		      (with-temp-buffer
			(url-insert-buffer-contents buffer url)
			(setf (slot-value this 'src) (gikopoi-make-data-uri url))))) nil t t))
  (cl-call-next-method))

(cl-defmethod shared-initialize :after ((this gikopoi-object) initargs)
  (setf (slot-value this 'dom-node)
	(dom-node 'image `((x . ,(slot-value this 'x))
			   (y . ,(slot-value this 'y))
			   (xlink:href . ,(slot-value this 'src))
			   (transform . ,(slot-value this 'transform))
			   (transform-origin . center)
			   (width . 100%) (height . 100%)))))


(cl-defmethod (setf gikopoi-object-src) (src (object gikopoi-object))
  (setf (slot-value object 'src) src
	(dom-attr (slot-value object 'dom-node) 'xlink:href) src))

(cl-defmethod (setf gikopoi-object-x) (x (object gikopoi-object))
  (setf (slot-value object 'x) x
	(dom-attr (slot-value object 'dom-node) 'x) x))

(cl-defmethod (setf gikopoi-object-y) (y (object gikopoi-object))
  (setf (slot-value object 'y) y
	(dom-attr (slot-value object 'dom-node) 'y) y))

(cl-defmethod (setf gikopoi-object-transform) (transform (object gikopoi-object))
  (setf (slot-value object 'transform) transform
	(dom-attr (slot-value object 'dom-node) 'transform) transform))


(defun gikopoi-make-object (room object)
  (let-alist object
    (make-instance 'gikopoi-object
		   :url .url
		   :room room
		   :position (cons .x .y)
		   :x (* (or .offset.x 0) (or .scale 1))
		   :y (* (or .offset.y 0) (or .scale 1)))))


;; Characters


(defvar gikopoi-character-buffer nil)

(defun gikopoi-read-character-from-buffer (id)
  (let ((string (format "\"%s\":" id))
	(case-fold-search nil))
    (with-current-buffer gikopoi-character-buffer
      (when (condition-case nil
		(search-backward string)
	      (search-failed (goto-char (point-max))
			     (search-backward string)))
	(forward-sexp)
	(forward-char)
	(json-read-object)))))

(defun gikopoi-intern-character (id)
  (when (null id) (setq id "giko"))
  (let ((symbol (intern-soft id)))
    (if (or (get symbol 'gikopoi-character-frames)
	    (null gikopoi-character-buffer)) symbol
      (when-let ((char (gikopoi-read-character-from-buffer id)))
	(let* ((base64 (cdar char))
	       (string (if base64 "data:image/png;base64," "data:image/svg+xml;utf8,"))
	       (frames (mapcar (lambda (x) (if (cdr x) (concat string (cdr x)))) (cdr char)))
	       (symbol (intern id)))
	  (put symbol 'gikopoi-character-frames (vconcat frames))
	  symbol)))))

(defun gikopoi-load-characters-into-buffer (server &rest _args)
  (url-retrieve (format "https://%s/characters/regular" server)
		(lambda (_status)
		  (setq gikopoi-character-buffer (current-buffer))
		  (goto-char (point-max))) nil t t))


;; TODO: Graphics


(defconst gikopoi-svg-canvas (svg-create 0 0))
(defvar gikopoi-graphics-buffer nil)

(defun gikopoi-fit-canvas-to-window-body (window)
  (setf (dom-attr gikopoi-svg-canvas 'width) (window-body-width window t)
	(dom-attr gikopoi-svg-canvas 'height) (window-body-height window t)))

(defun gikopoi-init-graphics-buffer ()
  (setq gikopoi-graphics-buffer (get-buffer-create "*--Gikopoi--*"))
  (with-current-buffer gikopoi-graphics-buffer
    (gikopoi-mode)
    (setq buffer-read-only t)
    (let ((buffer-read-only nil))
      (erase-buffer)
      (svg-insert-image gikopoi-svg-canvas))
    (add-hook 'window-size-change-functions
	      #'gikopoi-fit-canvas-to-window-body nil t)
    (display-buffer gikopoi-graphics-buffer)))

(defvar gikopoi-redraw-required-p nil)


(defun gikopoi-set-canvas-offset ())

(defun gikopoi-draw-background ())

(defun gikopoi-draw-objects ())

(defun gikopoi-draw-user-names ())

(defun gikopoi-draw-sleeping-icons ())

(defun gikopoi-draw-message-bubbles ())


(defun gikopoi-calculate-real-coordinates (room x y)
  (let* ((block-size (gikopoi-room-block-size room))
	 (origin (gikopoi-room-origin room))
	 (width-multiplier (/ (car block-size) 2))
	 (height-multiplier (/ (cdr block-size) 2)))
    (cons (+ (car origin) (* x width-multiplier) (* y width-multiplier))
	  (+ (cdr origin) (- (* x height-multiplier) (* y height-multiplier))))))


(defun gikopoi-calculate-physical-position (user room delta)
  (unless (or (zerop delta)
	      ())))



(defun gikopoi-compare-users (a b)
  (let ((last-a (gikopoi-user-last-movement a))
	(last-b (gikopoi-user-last-movement b)))
    (cond ((< last-a last-b))
	  ((> last-a last-b) nil)
	  (t (string-lessp (gikopoi-user-id a)
			   (gikopoi-user-id b))))))

(defun gikopoi-priority-sort (a b)
  (let ((y (1+ (cdr (gikopoi-room-size gikopoi-current-room))))
	(a (gikopoi-object-position a))
	(b (gikopoi-object-position b)))
    (< (+ y (car a) (- (cdr a)))
       (+ y (car b) (- (cdr b))))))

;; FIXME: Meant to sort objects according to their size, don't know how to get it from SVGs
(defalias 'gikopoi-diagonal-sort 'gikopoi-priority-sort)

;; (let ((users (sort (gikopoi-room-users room) #'gikopoi-compare-users))
;;       (sort-method (if (equal (gikopoi-room-sort-method room) "diagonal_scan")
;; 		       #'gikopoi-diagonal-sort #'gikopoi-priority-sort)))
;;   (sort (nconc (mapcar #'gikopoi-user-object users) (gikopoi-room-objects room)) sort-method))



(defun gikopoi-get-user-object (user frame)
  (let ((char (gikopoi-intern-character (gikopoi-user-character-id user)))
	(direction (gikopoi-user-direction user))
	(object (gikopoi-user-object user)))
    (when (member direction '("up" "left")) (cl-incf frame 4))
    (setf (gikopoi-object-transform object)
	  (if (member direction '("right" "up")) "scale(1,1)" "scale(-1,1)")
	  (gikopoi-object-src object)
	  (aref (get char 'gikopoi-character-frames) frame))
    object))

;; info box
(gikopoi-defevent server-stats ((userCount streamCount)))




;; Server Messages


(gikopoi-defevent server-system-message (code message)
  (message "SYSTEM: %s" code)
  (gikopoi-with-message-buffer (insert (format "SYSTEM: %s\n" message))))

(gikopoi-defevent server-reject-movement ())

(gikopoi-defevent server-ok-to-stream ())

(gikopoi-defevent server-not-ok-to-stream (reason))

(gikopoi-defevent server-not-ok-to-take-stream (slot))


(defun gikopoi-read-arglist ()
  (let* ((minibuffer-completion-confirm 'confirm)
	 (server (or gikopoi-default-server
		     (completing-read "Server: " (mapcar #'car gikopoi-servers))))
	 (port (or (when gikopoi-prompt-port-p
		     (string-to-number (read-string "Port: ")))
		   gikopoi-default-port))
	 (area (or gikopoi-default-area
		   (completing-read "Area: " (cdr (assoc server gikopoi-servers)))))
	 (room (or gikopoi-default-room
		   (read-string "Room: ")))
	 (name (or gikopoi-default-name
		   (read-string "Name (RET if none): ")))
	 (character (or gikopoi-default-character
			(read-string "Character (RET if none): ")))
	 (password (or (when gikopoi-prompt-password-p (read-passwd "Password: "))
		       gikopoi-default-password)))
    (list server port area room name character password)))



(defvar gikopoi-init-functions
  (list #'gikopoi-init-site-directory
	#'gikopoi-init-lang-alist
	#'gikopoi-connect
	#'gikopoi-init-message-buffer
;;	#'gikopoi-load-characters-into-buffer
	#'gikopoi-print-single-timestamp
	#'gikopoi-print-timestamps)
  "Lists of functions to run in order to initialize the client.
The functions are called with the elements returned by `gikopoi-read-arglist'.")


;;;###autoload
(defun gikopoi (server port area room name character password)
  (interactive (gikopoi-read-arglist))
  (run-hooks 'gikopoi-quit-functions)
  (run-hook-with-args 'gikopoi-init-functions
		      server port area room name character password))


(provide 'gikopoi)

;;; gikopoi.el ends here
