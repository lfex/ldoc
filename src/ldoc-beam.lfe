;;;; Read EEP-48 documentation from explicit BEAM artifacts.

(defmodule ldoc-beam
  (export
   (read-docs 1)
   (collect 1)
   (collect 2)))

(defspec (read-docs 1)
  ([(UNION (nonempty_string) (binary))]
   (UNION (tuple 'ok (map))
          (tuple 'error (tuple 'read_beam (term)))
          (tuple 'error (UNION 'invalid_beam 'missing_docs 'invalid_docs)))))

(defspec (collect 1)
  ([(UNION (nonempty_string) (binary))]
   (UNION (tuple 'ok (map))
          (tuple 'error (tuple 'read_beam (term)))
          (tuple 'error (tuple 'read_sidecar (term)))
          (tuple 'error
                 (UNION 'invalid_beam 'missing_docs 'invalid_docs
                        'invalid_sidecar_association)))))

(defspec (collect 2)
  ([(UNION (nonempty_string) (binary))
   (tuple 'edoc (UNION (nonempty_string) (binary)) (list))]
   (UNION (tuple 'ok (map))
          (tuple 'error (tuple 'read_beam (term)))
          (tuple 'error (tuple 'read_sidecar (term)))
          (tuple 'error
                 (UNION 'invalid_beam 'missing_docs 'invalid_docs
                        'invalid_sidecar_association
                        'invalid_edoc_provenance)))))

(defun read-docs (path)
  "Read embedded Docs metadata from a trusted local BEAM file."
  (case (read-artifact path)
    (`#(missing ,_module)
     '#(error missing_docs))
    (result result)))

(defun collect (path)
  "Collect embedded or associated sidecar Docs from a trusted BEAM path."
  (collect-artifact path 'none))

(defun collect (path provenance)
  "Collect Docs and optionally attach caller-declared EDoc conversion context."
  (case provenance
    (`#(edoc ,source-path ,include-dirs)
     (if (andalso (valid-path? source-path)
                  (valid-include-paths? include-dirs))
         (collect-artifact path
                           (edoc-conversion source-path include-dirs))
         '#(error invalid_edoc_provenance)))
    (_ '#(error invalid_edoc_provenance))))

(defun valid-path? (path)
  (if (is_binary path)
      (> (byte_size path) 0)
      (andalso (is_list path)
               (not (=:= path '()))
               (io_lib:char_list path))))

(defun valid-include-paths? (paths)
  (case paths
    (() 'true)
    ((cons path tail)
     (andalso (valid-path? path)
              (valid-include-paths? tail)))
    (_ 'false)))

(defun edoc-conversion (source-path include-dirs)
  `#m(tool edoc
      source_path ,source-path
      include_paths ,include-dirs
      evidence caller_declared))

(defun collect-artifact (path conversion)
  (case (read-artifact path)
    (`#(missing ,module)
     (collect-sidecar path module conversion))
    (result result)))

(defun read-artifact (path)
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
        `#(missing ,module))
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

(defun collect-sidecar (path module conversion)
  (case (sidecar-paths path module)
    (`#(candidate ,root ,relative-beam ,relative-chunk ,chunk-path)
     (case (filelib:safe_relative_path relative-chunk root)
       (safe-chunk (when (=:= safe-chunk relative-chunk))
        (case (file:read_file chunk-path)
          (`#(ok ,chunk-bytes)
           (case (filelib:safe_relative_path relative-beam root)
             (safe-beam (when (=:= safe-beam relative-beam))
              (ldoc-eep48:decode
               module (sidecar-source path chunk-path conversion) chunk-bytes))
             (_ '#(error invalid_sidecar_association))))
          (`#(error enoent)
           '#(error missing_docs))
          (`#(error ,reason)
           `#(error #(read_sidecar ,reason)))))
       (_ '#(error invalid_sidecar_association))))
    (_ '#(error missing_docs))))

(defun sidecar-paths (path module)
  (let* ((absolute-beam (filename:absname path))
         (ebin-dir (filename:dirname absolute-beam))
         (package-root (filename:dirname ebin-dir))
         (ebin-name (filename:basename ebin-dir)))
    (if (is_binary ebin-name)
        (if (=:= ebin-name #b("ebin"))
            (package-sidecar-paths absolute-beam package-root module)
            '#(no_candidate))
        (if (=:= ebin-name "ebin")
            (package-sidecar-paths absolute-beam package-root module)
            '#(no_candidate)))))

(defun package-sidecar-paths (absolute-beam package-root module)
  (let* ((beam-name (filename:basename absolute-beam))
         (binary-path? (is_binary absolute-beam))
         (chunk-name (lists:concat (list (atom_to_list module) ".chunk"))))
    (if (single-relative-component? chunk-name)
        (let ((relative-beam (if binary-path?
                                 (filename:join (list #b("ebin") beam-name))
                                 (filename:join (list "ebin" beam-name))))
              (relative-chunk
               (filename:join (list "doc" "chunks" chunk-name))))
          `#(candidate ,package-root ,relative-beam ,relative-chunk
                       ,(filename:join package-root relative-chunk)))
        '#(no_candidate))))

(defun single-relative-component? (path)
  (andalso (=:= (filename:pathtype path) 'relative)
           (case (filename:split path)
             (`(,only) (=:= only path))
             (_ 'false))))

(defun sidecar-source (path chunk-path conversion)
  (if (=:= conversion 'none)
      `#m(carrier eep48_sidecar path ,chunk-path beam_path ,path)
      `#m(carrier eep48_sidecar
          path ,chunk-path
          beam_path ,path
          conversion ,conversion)))
