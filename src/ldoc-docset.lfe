;;;; Assemble complete module maps into an exact, in-memory release docset.

(defmodule ldoc-docset
  "Validate an exact release key and assemble a complete sorted in-memory
docset from caller-selected trusted BEAM artifacts."
  (export
   (assemble 2)
   (valid-release? 1)))

(defspec (valid-release? 1)
  ([(term)] (boolean)))

(defspec (assemble 2)
  ([(map) (list)]
   (UNION (tuple 'ok (map))
          (tuple 'error (term)))))

(defun assemble (release inputs)
  "Assemble RELEASE and INPUTS into one complete in-memory docset.

RELEASE must contain exactly nonempty valid UTF-8 binaries for `namespace`,
`package`, and `version`. INPUTS is a nonempty proper list of trusted BEAM
paths or `{Path, Provenance}` descriptors. Success returns `{ok, Docset}` with complete
module maps sorted by normalized binary name. Invalid release returns
`{error, invalid_release_key}`; empty or improper inputs return `{error, invalid_inputs}`; an invalid descriptor
returns `{error, {invalid_input, Index}}`; collection failure returns `{error, {collect_failed, Path, Reason}}`; duplicate module
identity returns `{error, {duplicate_module, Name, FirstPath, Path}}`. No partial docset is returned. Collection reads
artifacts but does not load target code or write files."

  (case (valid-release? release)
    ('false '#(error invalid_release_key))
    ('true
     (if (valid-input-list? inputs)
         (case (validate-descriptors inputs 1)
           (`#(error ,reason) `#(error ,reason))
           ('ok (collect-inputs release inputs #m() '())) )
         '#(error invalid_inputs)))))

(defun valid-release? (release)
  "Return whether RELEASE is exactly the supported three-key release map.

Each namespace, package, and version value must be a nonempty valid UTF-8
binary. The result is a boolean predicate used by assembly and storage; it
does not authenticate a release against BEAM contents."

  (andalso (is_map release)
           (=:= (maps:size release) 3)
           (maps:is_key 'namespace release)
           (maps:is_key 'package release)
           (maps:is_key 'version release)
           (valid-release-value? (maps:get 'namespace release))
           (valid-release-value? (maps:get 'package release))
           (valid-release-value? (maps:get 'version release))))

(defun valid-release-value? (value)
  (if (andalso (is_binary value) (> (byte_size value) 0))
      (case (unicode:characters_to_binary value 'utf8 'utf8)
        (converted (when (is_binary converted)) 'true)
        (_ 'false))
      'false))

(defun valid-input-list? (inputs)
  (case inputs
    (() 'false)
    ((cons _ rest) (proper-list? rest))
    (_ 'false)))

(defun proper-list? (inputs)
  (case inputs
    (() 'true)
    ((cons _ rest) (proper-list? rest))
    (_ 'false)))

(defun validate-descriptors (inputs index)
  (case inputs
    (() 'ok)
    ((cons descriptor rest)
     (if (valid-descriptor? descriptor)
         (validate-descriptors rest (+ index 1))
         `#(error #(invalid_input ,index))))
    (_ '#(error invalid_inputs))))

(defun valid-descriptor? (descriptor)
  (case descriptor
    ((tuple path provenance) (valid-path? path))
    (path (valid-path? path))))

(defun valid-path? (path)
  (if (is_binary path)
      (> (byte_size path) 0)
      (andalso (is_list path)
               (not (=:= path '()))
               (io_lib:char_list path))))

(defun collect-inputs (release inputs seen reversed-modules)
  (case inputs
    (()
     `#(ok #m(release ,release
                 modules ,(lists:sort
                           (lambda (left right)
                             (< (maps:get 'name left)
                                (maps:get 'name right)))
                           reversed-modules))))
    ((cons descriptor rest)
     (let* ((path (descriptor-path descriptor))
            (result (collect-descriptor descriptor)))
       (case result
         (`#(error ,reason)
          `#(error #(collect_failed ,path ,reason)))
         (`#(ok ,module)
          (let ((name (maps:get 'name module)))
            (case (maps:find name seen)
              (`#(ok ,first-path)
               `#(error #(duplicate_module ,name ,first-path ,path)))
              ('error
               (collect-inputs release rest
                               (maps:put name path seen)
                               (cons module reversed-modules)))))))))))

(defun descriptor-path (descriptor)
  (case descriptor
    ((tuple path _provenance) path)
    (path path)))

(defun collect-descriptor (descriptor)
  (case descriptor
    ((tuple path provenance)
     (ldoc-beam:collect path provenance))
    (path
     (ldoc-beam:collect path))))
