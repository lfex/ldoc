(defmodule ldoc-fixture
  "Fixture module."
  (export (sample 1) (sample 2) (bare 0))
  (export-macro show))

(defun sample (value)
  "One argument."
  value)

(defun sample (value other)
  "Two arguments."
  (list value other))

(defun bare () 'ok)

;; Private definitions do not appear in the docs index.
(defun private-fun () 'ok)



(defmacro show (value)
  "Display one argument."
  `(io:format "~p" (list ,value)))
