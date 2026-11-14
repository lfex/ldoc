;;;; Read EEP-48 documentation from explicit BEAM artifacts.

(defmodule ldoc-beam
  "Read trusted BEAM documentation carriers with explicit precedence and
package-sidecar association. Collection reads files but never loads the
target module or searches the code path."
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
                        'invalid_ldoc 'invalid_sidecar_association)))))

(defspec (collect 2)
  ([(UNION (nonempty_string) (binary))
   (tuple 'edoc (UNION (nonempty_string) (binary)) (list))]
   (UNION (tuple 'ok (map))
          (tuple 'error (tuple 'read_beam (term)))
          (tuple 'error (tuple 'read_sidecar (term)))
          (tuple 'error
                 (UNION 'invalid_beam 'missing_docs 'invalid_docs
                        'invalid_sidecar_association
                        'invalid_ldoc
                        'invalid_edoc_provenance)))))

(defun read-docs (path)
  "Read the embedded EEP-48 `Docs` chunk from the supplied trusted BEAM
path.

PATH is a nonempty binary or character-list filename. The function reads
that file and does not load its module, search the code path, or fall back
to another carrier. It returns `{ok, ModuleMap}` or `{error, Reason}`; read failures are
tagged `read_beam`, while malformed BEAM, absent Docs, and unsupported Docs
data return `invalid_beam`, `missing_docs`, or `invalid_docs`."

  (case (read-artifact path)
    (`#(missing ,_module ,_beam)
     '#(error missing_docs))
    (result result)))

(defun collect (path)
  "Collect documentation from PATH using embedded Docs, its associated
immediate-package sidecar, then classic LDoc embedded in the same BEAM.

PATH is a nonempty binary or character-list filename. A later carrier is
tried only when an earlier carrier is absent; a present malformed carrier is
an error. Sidecar association is checked against the BEAM module and safe
immediate `ebin`/package layout. The function reads files but never loads
target code or searches the code path. It returns `{ok, ModuleMap}` or a tagged
error for BEAM/sidecar reads, invalid BEAM or Docs, invalid sidecar
association, malformed classic LDoc, or missing documentation."

  (collect-artifact path 'none))

(defun collect (path provenance)
  "Collect documentation from PATH with optional caller-declared EDoc
conversion context.

PROVENANCE must be `{edoc, Source, Includes}` with a nonempty path and a proper list of valid
include paths. This provenance value is validated before artifact
collection, even when embedded Docs take precedence. Conversion context is
recorded only if a sidecar is selected. The function does not run EDoc or
authenticate the source claim. Carrier precedence and absence-only fallback
match `collect/1`. Invalid provenance returns `invalid_edoc_provenance`; selected carrier,
association, and file failures retain their specific tagged errors. No
target module is loaded."

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
    (`#(missing ,module ,beam)
     (case (collect-sidecar path module conversion)
       (`#(error missing_docs)
        (read-legacy path module beam))
       (result result)))
    (result result)))

(defun read-artifact (path)
  (case (file:read_file path)
    (`#(ok ,beam)
     (read-beam path beam))
    (`#(error ,reason)
     `#(error #(read_beam ,reason)))))

(defun read-beam (path beam)
  (case (read-beam-chunks beam '("Docs"))
    (`#(ok #(,module ,chunks))
     (case (lists:keyfind "Docs" 1 chunks)
       (`#("Docs" missing_chunk)
        `#(missing ,module ,beam))
       (`#("Docs" ,docs-bytes)
        (ldoc-eep48:decode
         module
         `#m(carrier embedded_beam path ,path chunk #b("Docs"))
         docs-bytes))))
    (`#(error beam_lib ,_)
     '#(error invalid_beam))
    (`#(error invalid_beam)
     '#(error invalid_beam))))

(defun read-beam-chunks (beam chunks)
  (try
    (beam_lib:chunks beam chunks '(allow_missing_chunks))
    (catch
      (`#(error #(badmatch #(EXIT #(function_clause ,_))) ,_)
       '#(error invalid_beam))
      (`#(error #(badmatch #(EXIT #(badarg ,_))) ,_)
       '#(error invalid_beam))
      (`#(error #(badmatch #(EXIT #(#(badmatch ,_) ,_))) ,_)
       '#(error invalid_beam))
      (`#(error #(badmatch #(EXIT #(badmatch ,_))) ,_)
       '#(error invalid_beam)))))

(defun read-legacy (path original-module beam)
  (case (read-beam-chunks beam '("LDoc"))
    (`#(ok #(,scanned-module ,chunks))
     (if (=:= scanned-module original-module)
         (case (lists:keyfind "LDoc" 1 chunks)
           (`#("LDoc" missing_chunk)
            '#(error missing_docs))
           (`#("LDoc" ,legacy-bytes)
            (ldoc-legacy:decode
             original-module
             `#m(carrier embedded_beam
                 path ,path
                 chunk #b("LDoc")
                 legacy_version lfe_docs_v1
                 format_policy lodox_markdown)
             legacy-bytes)))
         '#(error invalid_beam)))
    (`#(error beam_lib ,_)
     '#(error invalid_beam))
    (`#(error invalid_beam)
     '#(error invalid_beam))))

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
