;;; gikopoi.el --- Gikopoipoi client -*- lexical-binding: t; coding: utf-8 -*-

;; Copyright (C) 2024 Gikopoi Intl. Superstructure

;; Author: gyudon_addict◆hawaiiZtQ6
;; Homepage: https://github.com/gyudon-addict/gikomacs
;; Keywords: games, chat, client
;; Version: 693.2
;; Package-Requires: ((websocket "1.15"))

;; This file is NOT part of GNU Emacs.

;; This program is free exhibitionist software; you can redistribute it and/or modify it under
;; the terms of the Goatse Public License as published by the Gikopoi Intl. Superstructure;
;; either perversion 0.604753 of the License, or (at your option) any later perversion.
;;
;; You should have received a copy of the Goatse Public License along with this package.
;; If not, see <https://github.com/153/goatse-license>.

;;; Commentary:

;; This package contains a set of tools to interface with the Gikopoipoi AA chatroom.
;; Provided at the moment is a simple IRC-like interactive mode, and a few functions and hooks
;; suitable for user-scripting and automated bots.
;;
;; The version numbering scheme for the package is the major version of the Gikopoipoi server
;; the client is tested to be compatible with, composed with the minor version of the package.

;; Install websockets lib with M-x package-install RET websocket RET if you haven't already.

;; Thanks:
;; Ilfak's GikoHelloBot python code

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


(defvar gikopoi-api-alist
  '((areas . "/areas/areaid/rooms/roomid")
    (characters . "/characters/regular")
    (version . "/version")
    (login . "/login")
    (client-log . "/client-log")))

(defun gikopoi-api-url (server key)
  (concat "https://" server (cdr (assq key gikopoi-api-alist))))

(defun gikopoi-api-area-url (server area room)
  (replace-regexp-in-string "areaid" area
    (replace-regexp-in-string "roomid" room
      (gikopoi-api-url server 'areas))))

(defun gikopoi-url-json-contents (url)
  (with-temp-buffer (url-insert-file-contents url)
    (json-read)))

(defun gikopoi-url-text-contents (url)
  (with-temp-buffer (url-insert-file-contents url)
    (buffer-string)))

(defun gikopoi-version-of-server (server)
  (gikopoi-url-json-contents (gikopoi-api-url server 'version)))

(defun gikopoi-log-to-server (server message)
  (let ((url-request-method "POST")
	(url-request-extra-headers '(("Content-Type" . "text/plain")))
	(url-request-data (encode-coding-string message 'utf-8)))
    (gikopoi-url-text-contents (gikopoi-api-url server 'client-log))))

(defun gikopoi-login (server area room name character password)
  (let ((url-request-method "POST")
	(url-request-extra-headers '(("Content-Type" . "application/json")))
	(url-request-data (encode-coding-string
			    (json-encode
			      (cl-pairlis '(userName characterId areaId roomId password)
				          (list name character area room password))) 'utf-8)))
    (gikopoi-url-json-contents (gikopoi-api-url server 'login))))


;; Connecting


(defvar gikopoi-socket nil)

(cl-defun gikopoi-socket-open (server pid &optional (port 8085))
  (setq gikopoi-socket
    (websocket-open (format "ws://%s:%d/socket.io/?EIO=4&transport=websocket" server port)
		    :custom-header-alist `((private-user-id . ,pid) (perMessageDeflate . false))
		    :on-open (lambda (sock) (websocket-send-text sock "40"))
		    :on-close (lambda (sock) (websocket-send-text sock "41"))
		    :on-message #'gikopoi-socket-message-handler)))

(defun gikopoi-socket-close ()
  (websocket-close gikopoi-socket)
  (setq gikopoi-socket nil))

(defun gikopoi-socket-message-handler (sock frame)
  (let (id payload)
    (with-temp-buffer
      (save-excursion
        (insert (websocket-frame-text frame)))
      (setq id (thing-at-point 'number))
      (forward-thing 'word)
      (setq payload (ignore-errors (json-read))))
    (cond ((eql id 0) t) ; open packet, ignore
	  ((eql id 2) (websocket-send-text sock "3")) ; ping pong
	  ((eql id 40) t) ; open packet, ignore
	  ((eql id 42) (gikopoi-event-handler payload))
	  (t (message "Unrecognized packet %s %s" id payload)))))

(defun gikopoi-socket-emit (object)
  (websocket-send-text gikopoi-socket
    (concat "42" (encode-coding-string (json-encode object) 'utf-8))))


(cl-defun gikopoi-connect (server area room &optional (name "") (character "") password)
  (when (websocket-openp gikopoi-socket)
    (websocket-close gikopoi-socket))
  (let ((version (gikopoi-version-of-server server))
	(login (gikopoi-login server area room name character password)))
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
      (gikopoi-socket-open server .privateUserId))))


(defun gikopoi-disconnect ()
  (gikopoi-socket-close)
  (with-current-buffer gikopoi-message-buffer
    (kill-buffer-and-window))
  (when (buffer-live-p gikopoi-room-list-buffer)
    (kill-buffer gikopoi-room-list-buffer))
  (when (buffer-live-p gikopoi-user-list-buffer)
    (kill-buffer gikopoi-user-list-buffer)))


;; Message Buffer


(defvar gikopoi-message-buffer nil)

(defun gikopoi-init-message-buffer ()
  (setq gikopoi-message-buffer (generate-new-buffer "*Gikopoi*"))
  (with-current-buffer gikopoi-message-buffer
    (gikopoi-mode)
    (setq buffer-read-only t))
  (display-buffer gikopoi-message-buffer))

(defmacro gikopoi-with-message-buffer (&rest body)
  (declare (indent defun))
  `(with-current-buffer gikopoi-message-buffer
     (goto-char (point-max))
     (let ((buffer-read-only nil))
       ,@body)))


(defun gikopoi-insert-message (name message)
  (gikopoi-with-message-buffer
    (dolist (msg (split-string message "\n"))
      (insert (format "%s: %s\n" name msg)))))


;; Server/Messaging


(defvar gikopoi-event-alist nil)
 
(defun gikopoi-event-handler (event)
  (let ((fn (cdr (assoc (aref event 0) gikopoi-event-alist #'string-equal))))
    (if (null fn)
	(message "Unhandled event %s" event)
      (apply fn (cl-coerce (substring event 1) 'list)))))

(defmacro gikopoi-defevent (name &rest body)
  (declare (indent defun))
  (let ((fn `(lambda ,(car body) ,@(cdr body)))
	(event `(assoc ',name gikopoi-event-alist #'string-equal)))
    `(if (null ,event)
	 (push (cons ',name ,fn) gikopoi-event-alist)
      (setcdr ,event ,fn))))


(defcustom gikopoi-message-hook nil
  "Hook run when a message is recieved.
Calls with the name of the user who sent it and the message.")

(defcustom gikopoi-mention-hook nil
  "Hook run when a message which matches gikopoi-mention-regexp is recieved.
Calls with the name of the user who sent it and the message.")

(defcustom gikopoi-mention-regexp ""
  "Regexp to match for calling gikopoi-mention-hook.")

(defcustom gikopoi-ignore-list nil
  "List of names to ignore.
Won't print any messages or run any hooks on actions from the user.")

(gikopoi-defevent server-msg (id message)
  (gikopoi-user-set-activep id t)
  (unless (or (string-empty-p message)
	      (gikopoi-user-ignoredp id))
    (let ((name (gikopoi-user-name id)))
      (dolist (hook gikopoi-message-hook)
	(funcall hook name message))
	
      (when (string-match gikopoi-mention-regexp message)
	(dolist (hook gikopoi-mention-hook)
	  (funcall hook name message)))
      
      (gikopoi-insert-message name message))))

(gikopoi-defevent server-roleplay (id message)
  (unless (gikopoi-user-ignoredp id) 
    (let ((name (gikopoi-user-name id)))
      (gikopoi-with-message-buffer
        (insert (format "* %s %s\n" name message))))))

(gikopoi-defevent server-roll-die (id base sum arga &optional argb)
  (unless (gikopoi-user-ignoredp id)
    (let ((name (gikopoi-user-name id))
	  (times (or argb arga)))
      (gikopoi-with-message-buffer
       (insert (format "* %s rolled %d x d%d and got %s!\n"
		       name times base sum))))))

(gikopoi-defevent server-system-message (code message)
  (gikopoi-with-message-buffer
    (insert (format "* SYSTEM: %s %s\n" code message))))

(gikopoi-defevent server-move (alist)
; ((userId . id) (x . n) (y . n) (direction . dir)
;  (lastMovement . time) (isInstant . bool) (shouldSpinwalk . bool)
  (let-alist alist
    (gikopoi-user-set-activep .userId t)))

(gikopoi-defevent server-bubble-position (id direction)
  nil)

(gikopoi-defevent server-reject-movement ()
  nil)

(gikopoi-defevent server-character-changed (id char altp)
  nil)

(gikopoi-defevent server-update-current-room-streams (stream-alist-vector)
  nil)

(gikopoi-defevent server-stats (alist)
;; ((userCount . n) (streamCount . n))
  (let-alist alist
    nil))


(defcustom gikopoi-user-join-hook nil
  "Hook to run when a user joins the room. Called with the name of the user.")

(gikopoi-defevent server-user-joined-room (alist)
; ((id . id) (name . name) (position (x . n) (y . n)) (direction . dir)
;  (roomId . room) (characterId . char) (isInactive . bool) (bubblePosition . dir)
;  (voicePitch . n) (lastRoomMessage . text) (isAlternateCharacter . bool) (lastMovement . time))
  (let-alist alist
    (gikopoi-add-user .id .name t)
    (let ((name (gikopoi-user-name .id)))
      (dolist (hook gikopoi-user-join-hook)
	(funcall hook name))
      (gikopoi-with-message-buffer
	(insert (format "* %s has entered the room\n" name))))))

(defcustom gikopoi-user-leave-hook nil
  "Hook to run when a user leaves the room. Called with the name of the user.")

(gikopoi-defevent server-user-left-room (id)
  (let ((name (gikopoi-user-name id)))
    (unless (gikopoi-user-ignoredp id)
      (dolist (hook gikopoi-user-leave-hook)
	(funcall hook name))
      (gikopoi-with-message-buffer
        (insert (format "* %s has left the room\n" name))))
    (gikopoi-rem-user id)))


(gikopoi-defevent server-user-active (id)
  (gikopoi-user-set-activep id t))

(gikopoi-defevent server-user-inactive (id)
  (gikopoi-user-set-activep id nil)
  (unless (gikopoi-user-ignoredp id)
    (gikopoi-with-message-buffer
      (insert (format "* %s is away\n" (gikopoi-user-name id))))))


(gikopoi-defevent server-update-current-room-state (state-alist)
  (gikopoi-update-room-state state-alist))

(gikopoi-defevent server-room-list (room-alist-vector)
  (gikopoi-update-room-list room-alist-vector))


;; State


(defvar gikopoi-room-list (list nil)
  "The list of rooms in the area along with information about them.
Form: (NIL . ((ID [NAME AREA USER-COUNT STREAMERS]) ...))")

(defun gikopoi-room-list ()
  (gikopoi-socket-emit '(user-room-list))
  (sleep-for 0 100) ; wait for it to finish
  (cdr gikopoi-room-list))

(defun gikopoi-update-room-list (room-alist-vector)
  (seq-doseq (room-alist room-alist-vector)
    (let-alist room-alist
      (let ((entry (assoc .id gikopoi-room-list))
	    (count (number-to-string .userCount))
	    (streams (string-join .streamers " "))
	    (id .id)
	    (group .group))
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


(defvar gikopoi-user-alist nil
  "Form: ((ID NAME ACTIVEP IGNOREDP) ...)")

(defvar gikopoi-empty-name "Anonymous"
  "The name to display for users who haven't entered a name.
This will be changed later to use the local name.")

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

(defun gikopoi-user-list ()
  "Returns the list of current users in the form ((ID [NAME STATUS]) ...)"
  (mapcar (lambda (user)
	    `(,(car user) [,(cadr user)
			   ,(string-join
			      (list (if (caddr user) "" "Zz ")
				    (if (cadddr user) "I" "")))]))
	  gikopoi-user-alist))

(defun gikopoi-user-list-ignore-toggle ()
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


(defun gikopoi-update-room-state (state-alist)
  (let-alist state-alist
    (setq gikopoi-user-alist nil)
    (setcdr gikopoi-user-list nil)
    (seq-doseq (user-alist .connectedUsers)
      (let-alist user-alist
	(gikopoi-add-user .id .name (eq .isInactive :json-false))
	(unless (string-empty-p .lastRoomMessage)
	  (gikopoi-insert-message (gikopoi-user-name .id) .lastRoomMessage))))))


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


;; Language

(defcustom gikopoi-preferred-language current-iso639-language
  "The preferred language of the client.")

(defvar gikopoi-lang-alist nil
  "A large alist of lingual information.")

(defun gikopoi-init-lang-alist ()
  (with-temp-buffer
    (insert-file-contents (format "langs/%s" gikopoi-preferred-language))
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
  "Opens a message prompt with a quote of the message at point inserted.
Useful for quickly responding to messages in certain contexts.

The format of the quote is specified by the format string gikopoi-autoquote-format,
which takes the quoted string as it's single argument."
  (interactive)
  (let ((quote (buffer-substring (point) (line-end-position))))
    (minibuffer-with-setup-hook
	(lambda () (insert (format gikopoi-autoquote-format quote)))
      (call-interactively #'gikopoi-send-message))))


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

    (define-key map (kbd "ESC ESC") (lambda ()
				      (interactive)
				      (when (y-or-n-p "Are you sure you want to disconnect?")
					(gikopoi-disconnect))))
    map))

(define-minor-mode gikopoi-mode
  "Main interactive mode. For use in the message and display buffers."
  :init-value nil
  :lighter " Gikopoi"
  :keymap gikopoi-mode-map)


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
	#'gikopoi-init-lang-alist)
  "Lists of functions to run when initializing the client, before connecting.
Calls each function with no arguments."
  :type 'hook)

(defun gikopoi (server area room name character password)
  (interactive (gikopoi-read-arglist))
  (run-hooks 'gikopoi-init-functions)
  (gikopoi-connect server area room name character password))



(provide 'gikopoi)
