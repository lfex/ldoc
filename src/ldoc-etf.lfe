;;;; Decode one complete external term at the trusted BEAM boundary.

(defmodule ldoc-etf
  (export
   (decode 1)))

(defspec (decode 1)
  ([(binary)]
   (UNION (tuple 'ok (term)) (tuple 'error 'invalid_etf))))

(defun decode (bytes)
  (try
    (case (erlang:binary_to_term bytes '(used))
      (`#(,term ,used)
       (if (=:= used (byte_size bytes))
           `#(ok ,term)
           '#(error invalid_etf)))
      (_ '#(error invalid_etf)))
    (catch
      (`#(error badarg ,_)
       '#(error invalid_etf)))))
