;;;; Decode one complete external term at the trusted BEAM boundary.

(defmodule ldoc-etf
  "Decode one complete Erlang external term at the trusted local artifact
boundary; this is not an isolation boundary for hostile ETF."
  (export
   (decode 1)))

(defspec (decode 1)
  ([(binary)]
   (UNION (tuple 'ok (term)) (tuple 'error 'invalid_etf))))

(defun decode (bytes)
  "Decode BYTES as exactly one complete Erlang external term.

A trailing byte or decoder `badarg` returns `{error, invalid_etf}`; otherwise the
decoded term is returned as `{ok, Term}`. ETF decoding may allocate trusted
atoms and resources, so this boundary is not a hostile-input sandbox. It
performs no file IO and executes no target module code."
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
