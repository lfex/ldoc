;;;; Project exact release docsets into deterministic native analysis views.

(defmodule ldoc-analysis
  (export
   (view 1)
   (view 2)))

(defspec (view 1)
  ([(map)]
   (UNION (tuple 'ok (map))
          (tuple 'error (UNION 'invalid_options 'invalid_docset)))))

(defspec (view 2)
  ([(map) (map)]
   (UNION (tuple 'ok (map))
          (tuple 'error (UNION 'invalid_options 'invalid_docset)))))

(defun view (docset)
  "Return the public native analysis view of DOCSET.

  Selected documentation stays in native terms. Hidden module contents and
  internal entries are omitted. view/2 can add relative source references.
  Example: {ok, View} = 'ldoc-analysis':view(Docset)."
  (view docset (maps:new)))

(defun view (docset options)
  "Return DOCSET projected through the selected native field allowlist.

  OPTIONS is either an empty map or a map containing only source_root, an
  absolute UTF-8 path with no dot or dot-dot components. Options are checked
  before the complete docset structure. No files are inspected or loaded."
  (case (validate-options options)
    (`#(ok ,root)
     (if (valid-docset? docset)
         `#(ok ,(project-docset docset root))
         '#(error invalid_docset)))
    (_ '#(error invalid_options))))

;;;; Validation stays at the public boundary. Projectors trust validated data.

(defun validate-options (options)
  (cond
    ((andalso (is_map options) (=:= (maps:size options) 0))
     `#(ok 'none))
    ((andalso (is_map options)
              (=:= (maps:size options) 1)
              (maps:is_key 'source_root options))
     (case (absolute-path-components (maps:get 'source_root options))
       (`#(ok ,components) `#(ok ,components))
       (_ '#(error invalid_options))))
    ('true '#(error invalid_options))))

(defun valid-docset? (docset)
  (andalso (is_map docset)
           (=:= (maps:size docset) 2)
           (maps:is_key 'release docset)
           (maps:is_key 'modules docset)
           (ldoc-docset:valid-release? (maps:get 'release docset))
           (valid-modules? (maps:get 'modules docset) #m())))

(defun valid-modules? (modules seen)
  (case modules
    (() (> (maps:size seen) 0))
    ((cons module tail)
     (if (valid-module? module)
         (let ((name (maps:get 'name module)))
           (case (maps:is_key name seen)
             ('true 'false)
             ('false (valid-modules? tail (maps:put name 'true seen)))))
         'false))
    (_ 'false)))

(defun valid-module? (module)
  (andalso (is_map module)
           (has-nonempty-binary? module 'name)
           (has-nonempty-binary? module 'language)
           (has-nonempty-binary? module 'format)
           (valid-doc? (maps:get 'doc module 'missing))
           (maps:is_key 'entries module)
           (valid-entries? (maps:get 'entries module) #m())))

(defun valid-entries? (entries seen)
  (case entries
    (() 'true)
    ((cons entry tail)
     (if (valid-entry? entry)
         (let ((identity (entry-identity entry)))
           (case (maps:is_key identity seen)
             ('true 'false)
             ('false (valid-entries? tail (maps:put identity 'true seen)))))
         'false))
    (_ 'false)))

(defun valid-entry? (entry)
  (andalso (is_map entry)
           (has-nonempty-binary? entry 'kind)
           (has-nonempty-binary? entry 'name)
           (valid-arity? (maps:get 'arity entry 'missing))
           (valid-signatures? (maps:get 'signatures entry 'missing))
           (valid-doc? (maps:get 'doc entry 'missing))
           (valid-visibility? (maps:get 'visibility entry 'missing))))

(defun has-nonempty-binary? (map key)
  (case (maps:find key map)
    (`#(ok ,value) (andalso (is_binary value) (> (byte_size value) 0)))
    (_ 'false)))

(defun valid-arity? (arity)
  (or (=:= arity 'unknown)
      (andalso (is_integer arity) (>= arity 0))))

(defun valid-signatures? (signatures)
  (case signatures
    (() 'true)
    ((cons signature tail)
     (andalso (is_binary signature) (valid-signatures? tail)))
    (_ 'false)))

(defun valid-doc? (doc)
  (case doc
    ('none 'true)
    ('hidden 'true)
    ((map) (valid-doc-map? (maps:keys doc)))
    (_ 'false)))

(defun valid-doc-map? (keys)
  (case keys
    (() 'true)
    ((cons key tail)
     (andalso (is_binary key) (valid-doc-map? tail)))
    (_ 'false)))

(defun valid-visibility? (visibility)
  (or (=:= visibility 'candidate) (=:= visibility 'internal)))

(defun entry-identity (entry)
  `#(,(maps:get 'kind entry)
     ,(maps:get 'name entry)
     ,(maps:get 'arity entry)))

(defun absolute-path-components (path)
  (case (utf8-path path)
    (`#(ok ,binary-path)
     (case (absolute-path? binary-path)
       ('true `#(ok ,(path-components binary-path)))
       (_ '#(error invalid_path))))
    (_ '#(error invalid_path))))

(defun absolute-path? (path)
  (andalso (not (contains-nul? path))
           (=:= (filename:pathtype path) 'absolute)
           (not (has-dot-component? (filename:split path)))))

(defun utf8-path (path)
  (if (is_binary path)
      (utf8-path-value path)
      (case (flat-char-list? path)
        ('true (utf8-path-value path))
        (_ '#(error invalid_path)))))

(defun utf8-path-value (path)
  (case (unicode:characters_to_binary path 'utf8 'utf8)
    (binary
     (case (safe-path-bytes? binary)
       ('true `#(ok ,binary))
       (_ '#(error invalid_path))))
    (_ '#(error invalid_path))))

(defun safe-path-bytes? (path)
  (andalso (is_binary path)
           (> (byte_size path) 0)
           (not (contains-nul? path))))

(defun contains-nul? (path)
  (case (binary:match path #b(0))
    ('nomatch 'false)
    (_ 'true)))

(defun flat-char-list? (value)
  (case value
    ((cons _ _)
     (io_lib:char_list value))
    (_ 'false)))

(defun has-dot-component? (components)
  (case components
    (() 'false)
    ((cons component tail)
     (or (or (=:= component #b("."))
             (=:= component #b("..")))
         (has-dot-component? tail)))
    (_ 'true)))

(defun path-components (path)
  (lists:map #'path-component/1 (filename:split path)))

(defun path-component (component)
  (case (unicode:characters_to_binary component 'utf8 'utf8)
    (binary (when (is_binary binary)) binary)
    (_ 'invalid)))

(defun valid-source-path? (path)
  (case (absolute-path-components path)
    (`#(ok ,_components) 'true)
    (_ 'false)))

;;;; Projection keeps exact native values and constructs only allowlisted maps.

(defun project-docset (docset root)
  (let* ((release (maps:get 'release docset))
         (groups (group-modules (maps:get 'modules docset) root #m())))
    `#m(release ,release
        languages ,(language-views (maps:to_list groups)))))

(defun group-modules (modules root groups)
  (case modules
    (() groups)
    ((cons module tail)
     (let* ((language (maps:get 'language module))
            (projected (project-module module root))
            (current (maps:get language groups '())))
       (group-modules tail root
                      (maps:put language (cons projected current) groups))))))

(defun language-views (pairs)
  (case pairs
    (() ())
    (_ (language-views-sorted
        (lists:sort (lambda (left right) (< (element 1 left)
                                            (element 1 right)))
                    pairs)))))

(defun language-views-sorted (pairs)
  (case pairs
    (() ())
    ((cons pair tail)
     (let* ((name (element 1 pair))
            (modules (lists:sort (lambda (left right)
                                   (< (maps:get 'name left)
                                      (maps:get 'name right)))
                                 (element 2 pair))))
       (cons `#m(name ,name
                  modules ,modules)
             (language-views-sorted tail))))))

(defun project-module (module root)
  (let* ((doc (maps:get 'doc module))
         (base `#m(name ,(maps:get 'name module)
                   format ,(maps:get 'format module)
                   doc ,doc
                   definitions ,(if (=:= doc 'hidden)
                                    ()
                                    (definition-views module root)))))
    (if (=:= doc 'hidden)
        base
        (add-source base (module-source module root)))))

(defun definition-views (module root)
  (let ((definitions (candidate-definitions (maps:get 'entries module)
                                            module root '())))
    (lists:sort (lambda (left right)
                  (< (definition-key left) (definition-key right)))
                definitions)))

(defun candidate-definitions (entries module root reversed)
  (case entries
    (() reversed)
    ((cons entry tail)
     (case (maps:get 'visibility entry)
       ('candidate
        (candidate-definitions tail module root
                               (cons (project-definition entry module root)
                                     reversed)))
       ('internal (candidate-definitions tail module root reversed))))))

(defun project-definition (entry module root)
  (let* ((base `#m(kind ,(maps:get 'kind entry)
                     name ,(maps:get 'name entry)
                     arity ,(maps:get 'arity entry)
                     signatures ,(maps:get 'signatures entry)
                     doc ,(maps:get 'doc entry)))
         (with-patterns (case (maps:find 'patterns entry)
                          (`#(ok ,patterns)
                           (maps:put 'patterns patterns base))
                          (_ base))))
    (add-source with-patterns (entry-source entry module root))))

(defun definition-key (definition)
  `#(,(maps:get 'kind definition)
     ,(maps:get 'name definition)
     ,(maps:get 'arity definition)))

(defun add-source (view source)
  (case source
    ('none view)
    (_ (maps:put 'source source view))))

;;;; Source references use only recorded provenance beneath the declared root.

(defun module-source (module root)
  (case root
    ('none 'none)
    (_ (case (module-source-candidate module)
         ('none 'none)
         (path
          (case (relative-source path root)
            ('none 'none)
            (`#(ok ,relative)
             (source-reference relative
                               (preferred-line (maps:get 'metadata module #m())
                                               (maps:get 'annotation module
                                                         'undefined))))))))))

(defun module-source-candidate (module)
  (let* ((source (maps:get 'source module #m()))
         (conversion (map-value 'conversion source #m()))
         (metadata (maps:get 'metadata module #m()))
         (candidates (list (declared-edoc-path conversion)
                           (map-value 'source_path metadata 'none)
                           (annotation-file (maps:get 'annotation module
                                                      'undefined)))))
    (first-valid-path candidates)))

(defun map-value (key map default)
  (if (is_map map)
      (maps:get key map default)
      default))

(defun declared-edoc-path (conversion)
  (if (andalso (is_map conversion)
              (=:= (maps:get 'tool conversion 'undefined) 'edoc)
              (=:= (maps:get 'evidence conversion 'undefined)
                   'caller_declared))
      (maps:get 'source_path conversion 'none)
      'none))

(defun first-valid-path (paths)
  (case paths
    (() 'none)
    ((cons path tail)
     (if (valid-source-path? path)
         path
         (first-valid-path tail)))))

(defun entry-source (entry module root)
  (case root
    ('none 'none)
    (_ (let* ((module-path (module-source-candidate module))
              (metadata (maps:get 'metadata entry #m()))
              (source-anno (map-value 'source_anno metadata 'undefined))
              (entry-anno (maps:get 'annotation entry 'undefined))
              (explicit (preferred-annotation-file source-anno entry-anno)))
         (case (entry-source-path explicit module-path root)
           ('none 'none)
           (`#(ok ,relative)
            (source-reference relative
                              (preferred-line metadata entry-anno))))))))

(defun preferred-annotation-file (preferred fallback)
  (case (annotation-file preferred)
    ('none (annotation-file fallback))
    (path path)))

(defun annotation-file (annotation)
  (case (erl_anno:is_anno annotation)
    ('true (annotation-file-value (erl_anno:file annotation)))
    (_ 'none)))

(defun annotation-file-value (path)
  (case (utf8-path path)
    (`#(ok ,binary-path) binary-path)
    (_ 'none)))

(defun entry-source-path (explicit module-path root)
  (case explicit
    ('none
     (case module-path
       ('none 'none)
       (_ (relative-source module-path root))))
    (path
     (case (utf8-path path)
       (`#(ok ,utf8)
        (case (filename:pathtype utf8)
          ('absolute (relative-source utf8 root))
          ('relative (inherit-relative-basename utf8 module-path root))
          (_ 'none)))
       (_ 'none)))))

(defun inherit-relative-basename (path module-path root)
  (case module-path
    ('none 'none)
    (_ (case (relative-source module-path root)
         ('none 'none)
         (module-relative
          (let* ((path-parts (path-components path))
                 (module-parts (path-components module-path)))
            (case (andalso (=:= (length path-parts) 1)
                           (> (length module-parts) 0)
                           (=:= (hd path-parts) (lists:last module-parts)))
              ('true module-relative)
              (_ 'none))))))))

(defun relative-source (path root)
  (case (absolute-path-components path)
    (`#(ok ,components)
     (case (drop-prefix components root)
       ('outside 'none)
       (() 'none)
       (relative-path
        (case (utf8-path (filename:join relative-path))
          (`#(ok ,binary-path) `#(ok ,binary-path))
          (_ 'none)))))
    (_ 'none)))

(defun drop-prefix (path root)
  (case (andalso (>= (length path) (length root))
                 (=:= (lists:sublist path (length root)) root))
    ('true (lists:nthtail (length root) path))
    (_ 'outside)))

(defun preferred-line (metadata annotation)
  (case (metadata-line (map-value 'source_anno metadata 'undefined))
    ('none (annotation-line annotation))
    (line line)))

(defun metadata-line (annotation)
  (annotation-line annotation))

(defun annotation-line (annotation)
  (case (erl_anno:is_anno annotation)
    ('true
     (let ((line (erl_anno:line annotation)))
       (if (andalso (is_integer line) (> line 0)) line 'none)))
    (_ 'none)))

(defun source-reference (relative line)
  (case line
    ('none `#m(path ,relative))
    (_ `#m(path ,relative line ,line))))
