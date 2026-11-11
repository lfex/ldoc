;;;; Assemble complete module maps into an exact, in-memory release docset.

(defmodule ldoc-docset
  (export
   (assemble 2)))

(defspec (assemble 2)
  ([(map) (list)]
   (UNION (tuple 'ok (map))
          (tuple 'error (term)))))

(defun assemble (release inputs)
  "Assemble trusted local BEAM inputs into one complete release docset.

  RELEASE must be the exact three-key release map. INPUTS is a nonempty
  manifest of BEAM paths or {Path, Provenance} pairs. On success, the
  collector's complete module maps are sorted by their normalized binary
  names. For example:

      'ldoc-docset':assemble(
        #{namespace => <<\"local\">>, package => <<\"beam-fixtures\">>,
          version => <<\"2.0-rc1\">>},
        [\"_build/default/lib/app/ebin/module.beam\"]).

  The function reads only through ldoc-beam:collect/1,2. It does not load
  modules, change the code path, or write files. Invalid boundary inputs and
  collector failures are returned as tagged errors."
  (case (valid-release? release)
    ('false '#(error invalid_release_key))
    ('true
     (if (valid-input-list? inputs)
         (case (validate-descriptors inputs 1)
           (`#(error ,reason) `#(error ,reason))
           ('ok (collect-inputs release inputs #m() '())) )
         '#(error invalid_inputs)))))

(defun valid-release? (release)
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
