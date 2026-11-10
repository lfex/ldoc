;;;; Read EEP-48 documentation from an explicit BEAM artifact.

(defmodule ldoc-beam
  (export
   (read-docs 1)))

(defspec (read-docs 1)
  ([(UNION (nonempty_string) (binary))]
   (UNION (tuple 'ok (map))
          (tuple 'error (tuple 'read_beam (term)))
          (tuple 'error (UNION 'invalid_beam 'missing_docs 'invalid_docs)))))

(defun read-docs (path)
  "Read embedded Docs metadata from a trusted local BEAM file."
  (case (file:read_file path)
    (`#(ok ,beam)
     (read-beam path beam))
    (`#(error ,reason)
     `#(error #(read_beam ,reason)))))

(defun read-beam (path beam)
  (case (read-beam-chunks beam)
    (`#(ok #(,module ,chunks))
     (case (lists:keyfind "Docs" 1 chunks)
       (`#("Docs" missing_chunk)
        '#(error missing_docs))
       (`#("Docs" ,docs-bytes)
        (ldoc-eep48:decode
         module
         `#m(carrier embedded_beam path ,path chunk #b("Docs"))
         docs-bytes))))
    (`#(error beam_lib ,_)
     '#(error invalid_beam))
    (`#(error invalid_beam)
     '#(error invalid_beam))))

(defun read-beam-chunks (beam)
  (try
    (beam_lib:chunks beam '("Docs") '(allow_missing_chunks))
    (catch
      (`#(error #(badmatch #(EXIT #(function_clause ,_))) ,_)
       '#(error invalid_beam))
      (`#(error #(badmatch #(EXIT #(badarg ,_))) ,_)
       '#(error invalid_beam))
      (`#(error #(badmatch #(EXIT #(#(badmatch ,_) ,_))) ,_)
       '#(error invalid_beam))
      (`#(error #(badmatch #(EXIT #(badmatch ,_))) ,_)
       '#(error invalid_beam)))))
