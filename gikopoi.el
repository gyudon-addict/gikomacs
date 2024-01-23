;;; gikopoi.el --- Gikopoipoi client -*- lexical-binding: t -*-

;; Copyright (C) 2024 Gikopoi Intl. Superstructure

;; Author: gyudon_addict
;; Homepage: https://github.com/gyudon-addict/gikomacs
;; Keywords: games, chat, client
;; Version: 693.1
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

(defvar gikopoi-new-api-alist
  '((areas . "/api/areas/areaid/rooms/roomid")
    (characters . "/api/characters/regular")
    (version . "/api/version")
    (login . "/api/login")
    (client-log . "/api/client-log")))

(defun gikopoi-api-url (api server key)
  (concat "https://" server (cdr (assq key (if api gikopoi-new-api-alist gikopoi-api-alist)))))

(defun gikopoi-api-area-url (api server area room)
  (replace-regexp-in-string "areaid" area
    (replace-regexp-in-string "roomid" room
      (gikopoi-api-url api server 'areas))))

(defun gikopoi-url-json-contents (url)
  (with-temp-buffer (url-insert-file-contents url)
    (json-read)))

(defun gikopoi-url-text-contents (url)
  (with-temp-buffer (url-insert-file-contents url)
    (buffer-string)))

(defun gikopoi-version-of-server (server &optional api)
  (gikopoi-url-json-contents (gikopoi-api-url api server 'version)))

(defun gikopoi-log-to-server (api server message)
  (let ((url-request-method "POST")
	(url-request-extra-headers '(("Content-Type" . "text/plain")))
	(url-request-data (encode-coding-string message 'utf-8)))
    (gikopoi-url-text-contents (gikopoi-api-url api server 'client-log))))

(defun gikopoi-login (api server area room name character password)
  (let ((url-request-method "POST")
	(url-request-extra-headers '(("Content-Type" . "application/json")))
	(url-request-data (encode-coding-string
			    (json-encode
			      (cl-pairlis '(userName characterId areaId roomId password)
				          (list name character area room password))) 'utf-8)))
    (gikopoi-url-json-contents (gikopoi-api-url api server 'login))))

(defun gikopoi-request-room-state (api server area room &optional pid)
  (let ((url-request-method "GET")
	(url-request-extra-headers (unless (null pid)
				     `(("Authorization" . ,(concat "Bearer " pid))))))
    (gikopoi-url-json-contents
      (gikopoi-api-area-url api server area room))))


;; Connecting


(defvar gikopoi-socket nil)

(defun gikopoi-socket-open (server pid)
  (setq gikopoi-socket
    (websocket-open (concat "ws://" server ":8085/socket.io/?EIO=4&transport=websocket")
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


(defcustom gikopoi-connect-hook nil
  "Hook run after connecting to a server. Calls with no arguments.")

(cl-defun gikopoi-connect (server area room &optional (name "") (character "") password)
  (when (websocket-openp gikopoi-socket)
    (websocket-close gikopoi-socket))
  (let* ((version (gikopoi-version-of-server server))
	 (api (> version 722))
	 (login (gikopoi-login api server area room name character password)))
    (when (null login)
      (error "Login unsuccessful %s" login))
    (let-alist login
      (gikopoi-log-to-server api server
        (string-join (list (format-time-string "%a %b %d %Y %T GMT%z (%Z)") .userId
			   "window.EXPECTED_SERVER_VERSION:" (number-to-string version)
			   "loginMessage.appVersion:" (number-to-string .appVersion)
			   "DIFFERENT:" (if (eql version .appVersion) "false" "true")) " "))
      (gikopoi-init-message-buffer server)
      (gikopoi-log-to-server api server
 	(string-join (list (format-time-string "%a %b %d %Y %T GMT%z (%Z)") .userId
 			   (url-http-user-agent-string)) " "))
      (gikopoi-socket-open server .privateUserId)
      (dolist (hook gikopoi-connect-hook)
	(funcall hook)))))


(defcustom gikopoi-disconnect-hook nil
  "Hook run before disconnecting from a server. Calls with no arguments.")

(defun gikopoi-disconnect ()
  (dolist (hook gikopoi-disconnect-hook)
    (funcall hook))
  (gikopoi-socket-close)
  (with-current-buffer gikopoi-message-buffer
    (kill-buffer-and-window)))


;; Message Buffer


(defvar gikopoi-message-buffer nil)

(defun gikopoi-init-message-buffer (name)
  (setq gikopoi-message-buffer (generate-new-buffer name))
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

(defvar gikopoi-ignored-ids nil)

(gikopoi-defevent server-msg (id message)
  (unless (or (string-empty-p message)
	      (member id gikopoi-ignored-ids))
    (let ((name (gikopoi-user-name id)))
      (dolist (hook gikopoi-message-hook)
	(funcall hook name message))
	
      (when (string-match gikopoi-mention-regexp message)
	(dolist (hook gikopoi-mention-hook)
	  (funcall hook name message)))
      
      (gikopoi-insert-message name message))))

(gikopoi-defevent server-roleplay (id message)
  (unless (member id gikopoi-ignored-ids) 
    (let ((name (gikopoi-user-name id)))
      (gikopoi-with-message-buffer
        (insert (format "* %s %s\n" name message))))))

(gikopoi-defevent server-roll-die (id base sum arga &optional argb)
  (unless (member id gikopoi-ignored-ids)
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
  nil)

(gikopoi-defevent server-bubble-position (id direction)
  nil)

(gikopoi-defevent server-reject-movement ()
  nil)

(gikopoi-defevent server-character-changed (id char altp)
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
    (unless (member .id gikopoi-ignored-ids)
      (when (string-empty-p .name)
	(setq .name gikopoi-empty-name))
      (dolist (hook gikopoi-user-join-hook)
	(funcall hook .name))
      (gikopoi-with-message-buffer
        (insert (format "* %s has entered the room\n" .name))))))

(defcustom gikopoi-user-leave-hook nil
  "Hook to run when a user leaves the room. Called with the name of the user.")

(gikopoi-defevent server-user-left-room (id)
  (let ((name (gikopoi-user-name id)))
    (gikopoi-rem-user id)
    (unless (member id gikopoi-ignored-ids)
      (dolist (hook gikopoi-user-leave-hook)
	(funcall hook name))
      (gikopoi-with-message-buffer
        (insert (format "* %s has left the room\n" name))))))


(gikopoi-defevent server-user-active (id)
  (gikopoi-user-set-activep id t)
  (gikopoi-with-message-buffer
    (insert (format "* %s is active\n" (gikopoi-user-name id)))))

(gikopoi-defevent server-user-inactive (id)
  (gikopoi-user-set-activep id nil)
  (gikopoi-with-message-buffer
    (insert (format "* %s is away\n" (gikopoi-user-name id)))))


(gikopoi-defevent server-update-current-room-state (state-alist)
  (gikopoi-update-room-state state-alist))

(gikopoi-defevent server-room-list (room-alist-vector)
  (gikopoi-update-room-list room-alist-vector))


;; State


(defvar gikopoi-room-list (list nil)
  "The list of rooms in the area along with information about them.
Form: (NIL . ((ID [NAME GROUP USER-COUNT STREAMERS]) ...))
Right now NAME is the same as ID, and GROUP is the internal group name. This will be changed
later to use the local names instead.")

(defun gikopoi-update-room-list (room-alist-vector)
  (seq-doseq (room-alist room-alist-vector)
    (let-alist room-alist
      (let ((entry (assoc .id gikopoi-room-list))
	    (contents (vector .id .group (number-to-string .userCount) (string-join .streamers " "))))
	(if (null entry)
	    (push (list .id contents) (cdr gikopoi-room-list))
	  (setcar (cdr entry) contents))))))


(defvar gikopoi-room-list-buffer nil)

(defun gikopoi-init-room-list-buffer ()
  (setq gikopoi-room-list-buffer (generate-new-buffer "*Room List*"))
  (with-current-buffer gikopoi-room-list-buffer
    (tabulated-list-mode)
    (setq tabulated-list-format
      [("Room Name" 18 t)
       ("Group" 10 t)
       ("Users" 5 t)
       ("Streamers" 0 nil)])
    (tabulated-list-init-header)
    (add-hook 'tabulated-list-revert-hook
	      (lambda ()
		(setq tabulated-list-entries (gikopoi-room-list))) nil t)))


(defvar gikopoi-user-alist nil
  "Form: ((ID NAME ACTIVEP IGNOREDP) ...)")

(defun gikopoi-user (id &optional byname)
  (cl-find id gikopoi-user-alist :test #'equal :key (if byname #'cadr #'car)))

(defvar gikopoi-empty-name "Anonymous"
  "The name to display for users who haven't entered a name.
This will be changed later to use the local name.")

(defvar gikopoi-empty-character "giko"
  "The character to use for users who haven't chosen a character.")

(defun gikopoi-user-name (id)
  (let ((name (cadr (gikopoi-user id))))
    (if (string-empty-p name) gikopoi-empty-name name)))

(defun gikopoi-user-activep (id)
  (caddr (gikopoi-user id)))

(defun gikopoi-user-set-activep (id p)
  (setcar (cddr (gikopoi-user id)) p))

(defun gikopoi-user-ignoredp (id)
  (cadddr (gikopoi-user id)))

(defun gikopoi-user-set-ignoredp (id p)
  (setcar (cdddr (gikopoi-user id)) p))

(defun gikopoi-add-user (id name &optional activep ignoredp)
  (cl-pushnew (list id name activep ignoredp) gikopoi-user-alist :test #'equal :key #'car))

(defun gikopoi-rem-user (id)
  (setq gikopoi-user-alist
    (assoc-delete-all id gikopoi-user-alist)))


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
		(setq tabulated-list-entries (gikopoi-user-list))) nil t)))

(defun gikopoi-user-list ()
  "Returns the list of current users in the form ((ID [NAME STATUS]) ...)"
  (mapcar (lambda (user)
	    `(,(car user) [,(cadr user)
			   ,(string-join
			      (list (if (caddr user) "" "Zz ")
				    (if (cadddr user) "I" "")))]))
	  gikopoi-user-alist))

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
    (seq-doseq (user-alist .connectedUsers)
      (let-alist user-alist
	(gikopoi-add-user .id .name (eq .isInactive :json-false))
	(unless (or (string-empty-p .lastRoomMessage)
		    (member .id gikopoi-ignored-ids))
	  (when (string-empty-p .name)
	    (setq .name gikopoi-empty-name))
	  (gikopoi-insert-message .name .lastRoomMessage))))))


;; User/Messaging


(defun gikopoi-room-list ()
  (gikopoi-socket-emit '(user-room-list))
  (sleep-for 0 75)
  (cdr gikopoi-room-list))

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


;; Interactive


(defun gikopoi-send-message ()
  (interactive)
  (let (message)
    (while (not (string-empty-p
		  (setq message (read-from-minibuffer ""))))
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


(defvar gikopoi-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'gikopoi-send-message)
    (define-key map (kbd "RET") #'gikopoi-send-blank)

    (define-key map (kbd "C-r") #'gikopoi-list-rooms)
    (define-key map (kbd "C-l") #'gikopoi-list-users)

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
  "Enables Gikopoi mode. For use in the message and display buffers."
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
;   ("gikopoipoi.net" "for" "gen")
    ("gikopoi.hu" "int" "hun"))
  "List of connectable Gikopoipoi servers and their areas.
Form: ((SERVER AREAS ...) ...)")


(defun gikopoi-read-arglist ()
  (let (server)
    (list (setq server
	    (completing-read "Server: " (mapcar #'car gikopoi-servers)
			     nil nil gikopoi-default-server))
	  (completing-read "Area: " (cdr (assoc server gikopoi-servers))
			   nil nil gikopoi-default-area)
	  (read-string "Room: " gikopoi-default-room)
	  (read-string "Name: " gikopoi-default-name)
	  (read-string "Character: " gikopoi-default-character)
	  (when (or gikopoi-prompt-password-p gikopoi-default-password)
	    (read-passwd "Password: " gikopoi-default-password)))))

(defun gikopoi (server area room name character password)
  (interactive (gikopoi-read-arglist))
  (gikopoi-connect server area room name character password))



(provide 'gikopoi)
