;;; gikopoi.el --- Gikopoipoi client -*- lexical-binding: t; coding: utf-8 -*-

;; Copyright (C) 2024 Gikopoi Intl. Superstructure

;; Author: gyudon_addict◆hawaiiZtQ6
;; Homepage: https://github.com/gyudon-addict/gikomacs
;; Keywords: games, chat, client
;; Version: 693.3
;; Package-Requires: ((websocket "1.15"))

;; This file is NOT part of GNU Emacs.

;; This program is free exhibitionist software; you can redistribute it and/or modify it under
;; the terms of the Goatse Public License as published by the Gikopoi Intl. Superstructure;
;; either perversion 0.604753 of the License, or (at your option) any later perversion.
;;
;; You should have received a copy of the Goatse Public License along with this package.
;; If not, see <https://github.com/153/goatse-license>.

;;; Commentary:

;; This is the main file of the 'gikopoi' package, containing a set of utilities to interface
;; with a Gikopoipoi chat server. Basically everything required in order to use Gikopoi.

;; This file defines core client functionality, along with a simple IRC-like interactive mode,
;; with a few functions and hooks suitable for user-scripting.

;; The version numbering scheme for the package is the major version of the Gikopoipoi server
;; the client is tested to be compatible with, composed with the minor version of the package.

;; Usage:

;; Install websockets lib with M-x package-install RET websocket RET if you haven't already.
;; Connect to a Gikopoipoi server with M-x gikopoi. Type ESC twice to quit.
;; In the message buffer, type SPC to open the minibuffer and start sending messages.
;; Type RET to send, and RET again to quit typing. RET once more will clear your text bubble.
;; Consult 'gikopoi-mode-map' for further information on the mode's bindings.

;; Thanks:

;; Ilfak's GikoHelloBot python code
;; Archduke's giko.py <https://github.com/153/giko.py>

;;; Code:

(eval-when-compile
  (require 'subr-x)
  (require 'let-alist))

(require 'seq)
(require 'url)
(require 'json)
(require 'cl-lib)
(require 'thingatpt)
(require 'websocket)


;; API


(defun gikopoi-url-json-contents (url)
  (with-temp-buffer (url-insert-file-contents url)
    (json-read)))

(defun gikopoi-url-text-contents (url)
  (with-temp-buffer (url-insert-file-contents url)
    (buffer-string)))

(defun gikopoi-version-of-server (server)
  (gikopoi-url-json-contents (format "https://%s/version" server)))

(defun gikopoi-log-to-server (server message)
  (let ((url-request-method "POST")
	(url-request-extra-headers '(("Content-Type" . "text/plain")))
	(url-request-data (encode-coding-string message 'utf-8)))
    (gikopoi-url-text-contents (format "https://%s/client-log" server))))

(defun gikopoi-login (server area room name character password)
  (let ((url-request-method "POST")
	(url-request-extra-headers '(("Content-Type" . "application/json")))
	(url-request-data (encode-coding-string
			    (json-encode
			      (cl-pairlis '(userName characterId areaId roomId password)
				          (list name character area room password))) 'utf-8)))
    (gikopoi-url-json-contents (format "https://%s/login" server))))


;; Connecting


(defvar gikopoi-socket nil)

(defun gikopoi-socket-open (server pid &optional port)
  (setq gikopoi-socket
    (websocket-open (format "ws://%s:%d/socket.io/?EIO=4&transport=websocket" server (or port 8085))
		    :custom-header-alist `((private-user-id . ,pid) (perMessageDeflate . false))
		    :on-open (lambda (sock) (websocket-send-text sock "40"))
		    :on-close (lambda (sock) (websocket-send-text sock "41"))
		    :on-message #'gikopoi-socket-message-handler))
  (setf (websocket-client-data gikopoi-socket) (list server pid port))
  (setq gikopoi-socket-last-ping (current-time))
  gikopoi-socket)

(defun gikopoi-socket-close ()
  (websocket-close gikopoi-socket)
  (cancel-timer gikopoi-socket-ping-timer))

(defvar gikopoi-socket-interval nil)
(defvar gikopoi-socket-tolerance 1)
(defvar gikopoi-socket-timeout nil)
(defvar gikopoi-socket-last-ping nil)
(defvar gikopoi-socket-ping-timer nil)

(defun gikopoi-socket-attempt-reconnect ()
  (with-timeout (gikopoi-socket-timeout
		  (message "Connection timed out.")
		  (gikopoi-socket-close))
    (let ((client-data (websocket-client-data gikopoi-socket))
	  (on-close (websocket-on-close gikopoi-socket)))
      (cl-labels ((reconnect ()
		    (condition-case nil
			(progn (setf (websocket-on-close gikopoi-socket) #'identity)
			       (gikopoi-socket-close)
			       (message "Reconnecting...")
			       (apply #'gikopoi-socket-open client-data))
		      (error (sleep-for (/ gikopoi-socket-timeout 10))
			     (reconnect)))))
	(reconnect))
      (setf (websocket-on-close gikopoi-socket) on-close))))

(defvar gikopoi-reconnecting-p nil)

(defun gikopoi-socket-check-ping ()
  (when (> (float-time (time-since gikopoi-socket-last-ping))
	   (+ gikopoi-socket-interval gikopoi-socket-tolerance))
    (setq gikopoi-reconnecting-p t)
    (gikopoi-socket-attempt-reconnect)))

(defun gikopoi-socket-message-handler (sock frame)
  (let (id payload)
    (with-temp-buffer
      (save-excursion
        (insert (websocket-frame-text frame)))
      (setq id (thing-at-point 'number))
      (forward-thing 'word)
      (setq payload (ignore-error 'json-end-of-file (json-read))))
    (cond ((eql id 0) ; open
	   (let-alist payload
	     (setq gikopoi-socket-interval (/ .pingInterval 1000)
		   gikopoi-socket-timeout (/ .pingTimeout 1000))
	     (setq gikopoi-socket-ping-timer
	       (run-at-time nil gikopoi-socket-interval #'gikopoi-socket-check-ping))))
	  ((eql id 2) ; ping
	   (setq gikopoi-socket-last-ping (current-time)
		 gikopoi-reconnecting-p nil)
	   (websocket-send-text sock "3")) ; pong
	  ((eql id 40) t) ; open packet, ignore
	  ((eql id 42) (gikopoi-event-handler payload))
	  (t (message "Unrecognized packet %s %s" id payload)))))

(defun gikopoi-socket-emit (object)
  (websocket-send-text gikopoi-socket
    (concat "42" (encode-coding-string (json-encode object) 'utf-8))))


(defun gikopoi-connect (server area room &optional name character password)
  (when (websocket-openp gikopoi-socket)
    (gikopoi-socket-close))
  (let ((version (gikopoi-version-of-server server))
	(login (gikopoi-login server area room (or name "") (or character "") password)))
    (when (null login)
      (error "Login unsuccessful %s" login))
    (let-alist login
      (gikopoi-log-to-server server
        (string-join (list (format-time-string "%a %b %d %Y %T GMT%z (%Z)") .userId
			   "window.EXPECTED_SERVER_VERSION:" (number-to-string version)
			   "loginMessage.appVersion:" (number-to-string .appVersion)
			   "DIFFERENT:" (if (eql version .appVersion) "false" "true")) " "))
      (gikopoi-log-to-server server
 	(string-join (list (format-time-string "%a %b %d %Y %T GMT%z (%Z)") .userId
 			   (url-http-user-agent-string)) " "))
      (setq gikopoi-reconnecting-p nil)
      (gikopoi-socket-open server .privateUserId))))


;; Message Buffer


(defvar gikopoi-message-buffer nil)

(defun gikopoi-init-message-buffer (server &rest _args)
  (setq gikopoi-message-buffer (generate-new-buffer server))
  (with-current-buffer gikopoi-message-buffer
    (gikopoi-mode)
    (setq buffer-read-only t))
  (display-buffer gikopoi-message-buffer))

(defun gikopoi-kill-message-buffer ()
  (with-current-buffer gikopoi-message-buffer
    (kill-buffer-and-window)))

(defmacro gikopoi-with-message-buffer (&rest body)
  (declare (indent defun))
  `(with-current-buffer gikopoi-message-buffer
     (goto-char (point-max))
     (let ((buffer-read-only nil))
       ,@body)))

(defun gikopoi-insert-message (name message)
  (dolist (msg (split-string message "\n"))
    (insert (format "%s: %s\n" name msg))))


;; Server/Messaging


(defmacro gikopoi-defevent (name args &rest body)
  "Define a handler function for the event NAME, in a similar form as 'defun'.
Puts the function as the property 'gikopoi-event-fn' of the symbol NAME."
  (declare (indent defun))
  `(put ',name 'gikopoi-event-fn (lambda ,args ,@body)))

(defmacro gikopoi-event-fn (name)
  "The property 'gikopoi-event-fn' of the symbol NAME.
For use with advice macros like 'add-function'."
  `(get ,name 'gikopoi-event-fn))

(defun gikopoi-event-handler (event)
  (let ((fn (gikopoi-event-fn (intern (aref event 0))))
	(args (cl-coerce (substring event 1) 'list)))
    (if (null fn)
	(message "Unhandled event %s" event)
      (apply fn args))))


(defcustom gikopoi-mention-regexp ""
  "If a message you recieve matches this regexp, the name of the sender will be added to
'gikopoi-mentions' and 'gikopoi-mention-count' will be incremented.")

(defvar gikopoi-unread-count 0)
(defvar gikopoi-mention-count 0)
(defvar gikopoi-mentions nil)

(defun gikopoi-msg-wrapper (id function &optional active message predicate)
  (when active (gikopoi-user-set-activep id t))
  (unless (or (gikopoi-user-ignoredp id)
	      (string-empty-p message) predicate)
    (let ((name (gikopoi-user-name id)))
      (if (or (with-current-buffer gikopoi-message-buffer
		(not gikopoi-notif-mode))
	      (get-buffer-window gikopoi-message-buffer 'visible))
	  (setq gikopoi-unread-count 0 gikopoi-mention-count 0
		gikopoi-mentions nil)
	(cl-incf gikopoi-unread-count)
	(when (and message (string-match gikopoi-mention-regexp message))
	  (cl-incf gikopoi-mention-count)
	  (add-to-list 'gikopoi-mentions name))
	(force-mode-line-update))
      (gikopoi-with-message-buffer
	(funcall function name)))))

(gikopoi-defevent server-msg (id message)
  (gikopoi-msg-wrapper id (lambda (name)
			    (gikopoi-insert-message name message)) t message))

(gikopoi-defevent server-roleplay (id message)
  (gikopoi-msg-wrapper id (lambda (name)
			    (insert (format "* %s %s\n" name message))) t message))

(gikopoi-defevent server-roll-die (id base sum arga &optional argb)
  (gikopoi-msg-wrapper id (lambda (name)
			    (let ((times (or argb arga)))
			      (insert (format "* %s rolled %s x d%s and got %s!\n"
					      name times base sum)))) t))


(gikopoi-defevent server-system-message (code message)
  (gikopoi-with-message-buffer
    (insert (format "* SYSTEM: %s %s\n" code message))))

(gikopoi-defevent server-move (alist)
; ((userId . id) (x . n) (y . n) (direction . dir)
;  (lastMovement . time) (isInstant . bool) (shouldSpinwalk . bool)
  (let-alist alist
    (gikopoi-user-set-activep .userId t)))

(gikopoi-defevent server-bubble-position (id direction))

(gikopoi-defevent server-reject-movement ())

(gikopoi-defevent server-character-changed (id char altp))

(gikopoi-defevent server-update-current-room-streams (stream-alist-vector))

(gikopoi-defevent server-stats (alist))
;; ((userCount . n) (streamCount . n))


(gikopoi-defevent server-user-joined-room (user-alist)
  (let-alist user-alist
    (gikopoi-insert-user user-alist)
    (gikopoi-msg-wrapper .id (lambda (name)
			       (insert (format "* %s has entered the room\n" name))))))

(defun gikopoi-insert-user (user-alist)
  (let-alist user-alist
    (let ((id .id) (message .lastRoomMessage))
      (gikopoi-add-user id .name (eq .isInactive json-false))
      (gikopoi-msg-wrapper id (lambda (name)
				 (gikopoi-insert-message name message))
			   nil message gikopoi-reconnecting-p))))

(gikopoi-defevent server-user-left-room (id)
  (gikopoi-msg-wrapper id (lambda (name)
			    (insert (format "* %s has left the room\n" name))))
  (gikopoi-rem-user id))

(gikopoi-defevent server-user-active (id)
  (gikopoi-user-set-activep id t))

(gikopoi-defevent server-user-inactive (id)
  (gikopoi-user-set-activep id nil)
  (gikopoi-msg-wrapper id (lambda (name)
			    (insert (format "* %s is away\n" name)))))


(gikopoi-defevent server-update-current-room-state (state)
  (setq gikopoi-user-alist nil)
  (setcdr gikopoi-user-list nil)
  (let-alist state
    (seq-doseq (user-alist .connectedUsers)
      (gikopoi-insert-user user-alist))))


(gikopoi-defevent server-room-list (room-alist-vector)
  (gikopoi-update-room-list room-alist-vector))


;; State


(defvar gikopoi-room-list (list nil)
  "The list of rooms in the area along with information about them.
Form: (nil . ((ID [NAME AREA USER-COUNT STREAMERS]) ...))")

(defun gikopoi-room-list ()
  (gikopoi-socket-emit '(user-room-list))
  (sleep-for 0.1) ; wait for it to finish
  (cdr gikopoi-room-list))

(defun gikopoi-update-room-list (room-alist-vector)
  (seq-doseq (room-alist room-alist-vector)
    (let-alist room-alist
      (let* ((id .id)
	     (group .group)
	     (entry (assoc id gikopoi-room-list))
	     (count (number-to-string .userCount))
	     (streams (string-join .streamers " ")))
	(let-alist gikopoi-lang-alist
	  (let ((name (cdr (assoc id .room #'string-equal)))
		(area (cdr (assoc group .area #'string-equal))))
	    (setq name (or (when (consp name)
			     (cdr (assq 'sort_key name)))
			   name id))
	    (setq area (or (when (consp area)
			     (cdr (assq 'sort_key area)))
			   area group))
	    (if (null entry)
		(push (list id (vector name area count streams))
		      (cdr gikopoi-room-list))
	      (setf (aref (cadr entry) 2) count
		    (aref (cadr entry) 3) streams))))))))


(defun gikopoi-room-list-change-entry ()
  (interactive)
  (gikopoi-change-room (tabulated-list-get-id)))

(defvar gikopoi-room-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'gikopoi-room-list-change-entry)
    map))

(define-minor-mode gikopoi-room-list-mode
  "Mode for the Room List buffer."
  :lighter " #rula"
  :keymap gikopoi-room-list-mode-map)

(defvar gikopoi-room-list-buffer nil)

(defun gikopoi-init-room-list-buffer ()
  (setq gikopoi-room-list-buffer (generate-new-buffer "*Room List*"))
  (with-current-buffer gikopoi-room-list-buffer
    (tabulated-list-mode)
    (setq tabulated-list-format
      [("Room Name" 32 t)
       ("Group" 14 t)
       ("Users" 6 t)
       ("Streamers" 0 nil)])
    (tabulated-list-init-header)
    (add-hook 'tabulated-list-revert-hook
	      (lambda ()
		(setq tabulated-list-entries (gikopoi-room-list))) nil t)
    (gikopoi-room-list-mode)))

(defun gikopoi-kill-room-list-buffer ()
  (when (buffer-live-p gikopoi-room-list-buffer)
    (kill-buffer gikopoi-room-list-buffer)))


(defvar gikopoi-user-alist nil
  "Form: ((ID NAME ACTIVEP IGNOREDP) ...)")

(defvar gikopoi-empty-name "Anonymous"
  "The name to display for users who haven't entered a name.")

(defvar gikopoi-user-list (list gikopoi-empty-name))

(defun gikopoi-user (id &optional byname)
  (cl-find id gikopoi-user-alist :test #'equal :key (if byname #'cadr #'car)))

(defvar gikopoi-empty-character "giko"
  "The character to use for users who haven't chosen a character.")

(defun gikopoi-user-name (id)
  (cadr (gikopoi-user id)))

(defun gikopoi-user-activep (id)
  (caddr (gikopoi-user id)))

(defun gikopoi-user-set-activep (id p)
  (setcar (cddr (gikopoi-user id)) p))

(defun gikopoi-user-ignoredp (id)
  (cadddr (gikopoi-user id)))

(defun gikopoi-user-set-ignoredp (id p)
  (setcar (cdddr (gikopoi-user id)) p))

(defun gikopoi-add-user (id name &optional activep ignoredp)
  (if (string-empty-p name)
      (setq name gikopoi-empty-name)
    (cl-pushnew name (cdr gikopoi-user-list) :test #'equal))
  (cl-pushnew (list id name activep ignoredp) gikopoi-user-alist :test #'equal :key #'car))

(defun gikopoi-rem-user (id)
  (setcdr gikopoi-user-list
    (delete (gikopoi-user-name id) (cdr gikopoi-user-list)))
  (setq gikopoi-user-alist
    (assoc-delete-all id gikopoi-user-alist)))


(defvar gikopoi-user-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'gikopoi-user-list-ignore-toggle)
    map))

(define-minor-mode gikopoi-user-list-mode
  "Mode for the User List buffer."
  :lighter " #list"
  :keymap gikopoi-user-list-mode-map)


(defvar gikopoi-user-list-buffer nil)

(defun gikopoi-init-user-list-buffer ()
  (setq gikopoi-user-list-buffer (generate-new-buffer "*User List*"))
  (with-current-buffer gikopoi-user-list-buffer
    (tabulated-list-mode)
    (setq tabulated-list-format
      [("Users" 24 t)
       ("Status" 6 nil)])
    (tabulated-list-init-header)
    (add-hook 'tabulated-list-revert-hook
	      (lambda ()
		(setq tabulated-list-entries (gikopoi-user-list))) nil t)
    (gikopoi-user-list-mode)))

(defun gikopoi-kill-user-list-buffer ()
  (when (buffer-live-p gikopoi-user-list-buffer)
    (kill-buffer gikopoi-user-list-buffer)))

(defun gikopoi-user-list ()
  "Returns the list of current users in the form ((ID [NAME STATUS]) ...)"
  (mapcar (lambda (user)
	    `(,(car user) [,(cadr user)
			   ,(string-join
			      (list (if (caddr user) "" "Zz ")
				    (if (cadddr user) "I" "")))]))
	  gikopoi-user-alist))

(defun gikopoi-user-list-ignore-toggle ()
  "Toggles ignore on the user under point in the user list buffer."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (gikopoi-user-set-ignoredp id (not (gikopoi-user-ignoredp id))))
  (tabulated-list-revert))

(defun gikopoi-list-users ()
  "Populates and opens the user list buffer."
  (interactive)
  (unless (buffer-live-p gikopoi-user-list-buffer)
    (gikopoi-init-user-list-buffer))
  (with-current-buffer gikopoi-user-list-buffer
    (tabulated-list-revert))
  (unless (eq (current-buffer) gikopoi-user-list-buffer)
    (display-buffer gikopoi-user-list-buffer)))


;; User/Messaging


(defun gikopoi-change-room (room &optional door)
  (gikopoi-socket-emit
    `(user-change-room ((targetRoomId . ,room) (targetDoorId . ,door)))))

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


;; Environment


(defvar gikopoi-default-directory nil
  "The directory in which gikopoi.el resides.")

(cl-eval-when (load eval)
  (setq gikopoi-default-directory (file-name-directory load-file-name)))


(defcustom gikopoi-preferred-language current-iso639-language
  "The preferred language of the client.")

(defvar gikopoi-lang-alist nil
  "A large alist of lingual information.")

(defun gikopoi-init-lang-alist (&rest _args)
  (with-temp-buffer
    (insert-file-contents (format "%slangs/%s"
				  gikopoi-default-directory
				  gikopoi-preferred-language))
    (setq gikopoi-lang-alist (read (current-buffer))))
  (let-alist gikopoi-lang-alist
    (setq gikopoi-empty-name (or .default_user_name "Anonymous"))
    (setcar gikopoi-user-list gikopoi-empty-name)))


;; Interactive


(defun gikopoi-minibuffer-complete ()
  (interactive)
  (let ((bounds (bounds-of-thing-at-point 'word)))
    (completion-in-region (car bounds) (cdr bounds) gikopoi-user-list)))

(defvar gikopoi-minibuffer-map
  (let ((map (copy-keymap minibuffer-local-map)))
    (define-key map (kbd "TAB") #'gikopoi-minibuffer-complete)
    map))
 
(defun gikopoi-send-message ()
  (interactive)
  (let (message)
    (while (not (string-empty-p
		  (setq message
		    (read-from-minibuffer "" nil gikopoi-minibuffer-map))))
      (gikopoi-send message))))

(defun gikopoi-send-blank ()
  (interactive) (gikopoi-send ""))


(defun gikopoi-list-rooms ()
  "Populates and opens the room list buffer."
  (interactive)
  (unless (buffer-live-p gikopoi-room-list-buffer)
    (gikopoi-init-room-list-buffer))
  (with-current-buffer gikopoi-room-list-buffer
    (tabulated-list-revert))
  (unless (eq (current-buffer) gikopoi-room-list-buffer)
    (display-buffer gikopoi-room-list-buffer)))


(defun gikopoi-move-left (times)
  (interactive "p")
  (dotimes (i times)
    (gikopoi-move "left")))

(defun gikopoi-move-right (times)
  (interactive "p")
  (dotimes (i times)
    (gikopoi-move "right")))

(defun gikopoi-move-up (times)
  (interactive "p")
  (dotimes (i times)
    (gikopoi-move "up")))

(defun gikopoi-move-down (times)
  (interactive "p")
  (dotimes (i times)
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


(defcustom gikopoi-autoquote-format "> %s < "
  "The format string for gikopoi-autoquote.")

(defun gikopoi-autoquote ()
  "Opens a message prompt with a quote of the message at point inserted,
specified by 'gikopoi-autoquote-format'."
  (interactive)
  (let ((quote (buffer-substring (point) (line-end-position))))
    (minibuffer-with-setup-hook
	(lambda () (insert (format gikopoi-autoquote-format quote)))
      (call-interactively #'gikopoi-send-message))))


(defvar gikopoi-quit-functions
  (list #'gikopoi-socket-close
	#'gikopoi-kill-message-buffer
	#'gikopoi-kill-room-list-buffer
	#'gikopoi-kill-user-list-buffer
	(lambda () (gikopoi-notif-mode -1))))

(defun gikopoi-quit ()
  (interactive)
  (when (y-or-n-p "Are you sure you want to disconnect?")
    (run-hooks 'gikopoi-quit-functions)))


(defvar gikopoi-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'gikopoi-send-message)
    (define-key map (kbd "RET") #'gikopoi-send-blank)

    (define-key map (kbd "C-r") #'gikopoi-list-rooms)
    (define-key map (kbd "C-l") #'gikopoi-list-users)

    (define-key map (kbd "C-q") #'gikopoi-autoquote)

    (define-key map (kbd "<left>")  #'gikopoi-move-left)
    (define-key map (kbd "<right>") #'gikopoi-move-right)
    (define-key map (kbd "<up>")    #'gikopoi-move-up)
    (define-key map (kbd "<down>")  #'gikopoi-move-down)

    (define-key map (kbd "<C-left>")  #'gikopoi-bubble-left)
    (define-key map (kbd "<C-right>") #'gikopoi-bubble-right)
    (define-key map (kbd "<C-up>")    #'gikopoi-bubble-up)
    (define-key map (kbd "<C-down>")  #'gikopoi-bubble-down)

    (define-key map (kbd "ESC ESC") #'gikopoi-quit)

    map))

(define-minor-mode gikopoi-mode
  "Main interactive mode. For use in the message and display buffers."
  :init-value nil
  :lighter " Gikopoi"
  :keymap gikopoi-mode-map)



(defvar gikopoi-notif '(:eval (gikopoi-notif-string)))

(defcustom gikopoi-notif-position '(mode-line-modes . nil)
  "Describes how 'gikopoi-notif' shows up in the mode line.
It's either nil, or a cons whose car is a symbol and cdr is a boolean.
If it's a cons, 'gikopoi-notif' is added to the car's symbol-value:
at the beginning if the cdr is nil, or at the end if it's not.")

(define-minor-mode gikopoi-notif-mode
  "This mode displays information about unread messages in the mode-line."
  :init-value nil
  :lighter " Notif"

  (if (not gikopoi-notif-mode)
      (set (car gikopoi-notif-position)
	   (delete gikopoi-notif (symbol-value (car gikopoi-notif-position))))
    (add-to-list (car gikopoi-notif-position)
		 gikopoi-notif (cdr gikopoi-notif-position))))

(defun gikopoi-unique-prefix (string &optional collection)
  "Return the shortest unique prefix for STRING when compared to COLLECTION,
or 'gikopoi-user-list' if COLLECTION is unsupplied or nil.
It's assumed STRING is a member of COLLECTION, otherwise it doesn't work properly.
Whether or not this is worth fixing has yet to be determined."
  (when (null collection)
    (setq collection gikopoi-user-list))
  (let ((i 1) completion prefix)
    (cl-labels ((loop ()
		  (setq prefix (substring string 0 i)
			completion (try-completion prefix collection))
		  (cond ((member completion collection) prefix)
			((equal prefix completion)
			 (cl-incf i)
			 (loop))
			((< (length prefix) (length completion))
			 (setq i (length completion))
			 (loop)))))
      (loop))))

(defun gikopoi-notif-string ()
  (format "_%s %s" gikopoi-current-area
	  (if (zerop gikopoi-unread-count) ""
	    (format "%d%s" gikopoi-unread-count
		    (if (zerop gikopoi-mention-count) " "
		      (format ",%d%s " gikopoi-mention-count
			      (mapcar #'gikopoi-unique-prefix gikopoi-mentions)))))))



(defcustom gikopoi-timestamp-interval 3600
  "The interval in seconds to print a timestamp into the message buffer,
or nil to not print at all.")

(defcustom gikopoi-time-format "* %a %b %d %Y %T GMT%z (%Z)\n"
  "A 'format-time-string' format string with which to periodically print
timestamps into the message buffer.")

(defvar gikopoi-timestamp-timer nil)

(defun gikopoi-print-timestamps (&rest _args)
  (unless (null gikopoi-timestamp-interval)
    (setq gikopoi-timestamp-timer
      (run-at-time nil gikopoi-timestamp-interval
		   (lambda ()
		     (gikopoi-with-message-buffer
		       (insert (format-time-string gikopoi-time-format))))))
    (add-hook 'gikopoi-quit-functions
	      (lambda () (cancel-timer gikopoi-timestamp-timer)))))


(defcustom gikopoi-default-server nil "")
(defcustom gikopoi-default-name nil "")
(defcustom gikopoi-default-character nil "")
(defcustom gikopoi-default-area nil "")
(defcustom gikopoi-default-room nil "")
(defcustom gikopoi-default-password nil "")
(defcustom gikopoi-prompt-password-p nil "")


(defcustom gikopoi-servers
  '(("play.gikopoi.com" "for" "gen" "vip")
    ("gikopoi.hu" "int" "hun"))
  "List of connectable Gikopoipoi servers and their areas.
Form: ((SERVER AREAS ...) ...)")


(defun gikopoi-read-arglist ()
  (let* ((server (or gikopoi-default-server
		     (completing-read "Server: " (mapcar #'car gikopoi-servers))))
	 (area (or gikopoi-default-area
		   (completing-read "Area: " (cdr (assoc server gikopoi-servers)))))
	 (room (or gikopoi-default-room
		   (read-string "Room: ")))
	 (name (or gikopoi-default-name
		   (read-string "Name (RET if none): ")))
	 (character (or gikopoi-default-character
			(read-string "Character (RET if none): ")))
	 (password (or gikopoi-default-password
		       (when gikopoi-prompt-password-p (read-passwd "Password: ")))))
    (list server area room name character password)))

(defcustom gikopoi-init-functions
  (list #'gikopoi-init-message-buffer
	#'gikopoi-init-lang-alist
	#'gikopoi-connect
	#'gikopoi-print-timestamps)
  "Lists of functions to run when initializing the client, before connecting.
The functions are called with the elements of 'gikopoi-read-arglist'."
  :type 'hook)

(defcustom gikopoi-display-graphics-p t
  "Whether to invoke the 'gikopoi-gfx' feature upon starting Gikopoi.")

(defvar gikopoi-current-server nil)
(defvar gikopoi-current-area nil)

(defun gikopoi (server area room name character password)
  (interactive (gikopoi-read-arglist))
  (setq gikopoi-current-server server
	gikopoi-current-area area)
  (run-hook-with-args 'gikopoi-init-functions
		      server area room name character password))


(provide 'gikopoi)

;;; gikopoi.el ends here
