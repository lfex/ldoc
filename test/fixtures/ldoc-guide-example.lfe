(defmodule ldoc-guide-example
  "Small arithmetic examples for documentation authors."
  (export (increment 1) (sign 1))
  (export-macro tagged))

(defun increment (value)
  "Return VALUE plus one. VALUE must be a number."
  (+ value 1))

(defun sign
  "Classify an integer as negative, zero, or positive.

  Raises function_clause for a non-integer input."
  ((0) 'zero)
  ((value) (when (andalso (is_integer value) (< value 0))) 'negative)
  ((value) (when (andalso (is_integer value) (> value 0))) 'positive))

(defmacro tagged (value)
  "Expand to a tuple containing the atom tagged and VALUE."
  `(tuple 'tagged ,value))
