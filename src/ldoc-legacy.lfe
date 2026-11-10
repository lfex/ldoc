;;;; Normalize the versioned classic LFE LDoc record.

(defmodule ldoc-legacy
  (export
   (decode 3)))

(defspec (decode 3)
  ([(atom) (map) (binary)]
   (UNION (tuple 'ok (map)) (tuple 'error 'invalid_ldoc))))

(defun decode (module source chunk-bytes)
  (case (ldoc-etf:decode chunk-bytes)
    (`#(ok ,term)
     (normalize module source term))
    (_ '#(error invalid_ldoc))))

(defun normalize (module source term)
  (case term
    (`#(lfe_docs_v1 ,docs ,module-lines)
     (if (andalso (is_atom module)
                  (valid-doc-lines? module-lines)
                  (valid-doc-entries? docs))
         (case (normalized-entries docs)
           (`#(ok ,entries)
            (if (unique-entries? entries)
                `#(ok #m(name ,(atom_to_binary module 'utf8)
                          language #b("lfe")
                          format #b("text/markdown")
                          source ,source
                          annotation undefined
                          doc ,(normalized-doc module-lines)
                          metadata #m(legacy_doc_lines ,module-lines)
                          entries ,entries))
                '#(error invalid_ldoc)))
           (_ '#(error invalid_ldoc)))
         '#(error invalid_ldoc)))
    (_ '#(error invalid_ldoc))))

(defun valid-doc-lines? (lines)
  (case lines
    (() 'true)
    ((cons line tail)
     (andalso (is_binary line) (valid-doc-lines? tail)))
    (_ 'false)))

(defun valid-doc-entries? (docs)
  (case docs
    (() 'true)
    ((cons doc tail)
     (andalso (valid-doc-entry? doc) (valid-doc-entries? tail)))
    (_ 'false)))

(defun valid-doc-entry? (doc)
  (case doc
    (`#(doc function ,exported #(,name ,arity) ,patterns ,lines ,line)
     (andalso (is_boolean exported)
              (is_atom name)
              (is_integer arity)
              (>= arity 0)
              (valid-function-patterns? patterns)
              (valid-doc-lines? lines)
              (is_integer line)
              (> line 0)))
    (`#(doc macro ,exported ,name ,patterns ,lines ,line)
     (andalso (is_boolean exported)
              (is_atom name)
              (valid-macro-patterns? patterns)
              (valid-doc-lines? lines)
              (is_integer line)
              (> line 0)))
    (_ 'false)))

(defun valid-function-patterns? (patterns)
  (case patterns
    (() 'true)
    ((cons pattern tail)
     (andalso (valid-pattern-pair? pattern)
              (valid-function-patterns? tail)))
    (_ 'false)))

(defun valid-macro-patterns? (patterns)
  (andalso (proper-list? patterns)
           (or (valid-macro-pairs? patterns)
               (case patterns
                 ((cons _ ()) 'true)
                 (_ 'false)))))

(defun valid-macro-pairs? (patterns)
  (case patterns
    (() 'true)
    ((cons pattern tail)
     (andalso (valid-macro-pair? pattern)
              (valid-macro-pairs? tail)))
    (_ 'false)))

(defun valid-pattern-pair? (pattern)
  (case pattern
    (`#(,arguments ,guards)
     (andalso (proper-list? arguments) (proper-list? guards)))
    (_ 'false)))

(defun valid-macro-pair? (pattern)
  (case pattern
    (`#(,_pattern ,guards)
     (proper-list? guards))
    (_ 'false)))

(defun proper-list? (value)
  (case value
    (() 'true)
    ((cons _ tail) (proper-list? tail))
    (_ 'false)))

(defun normalized-entries (docs)
  (case (normalize-entries docs '())
    (`#(ok ,entries)
     `#(ok ,(lists:sort (lambda (left right)
                          (< (entry-key left) (entry-key right)))
                        entries)))
    (_ '#(error invalid_ldoc))))

(defun normalize-entries (docs acc)
  (case docs
    (() `#(ok ,acc))
    ((cons doc tail)
     (normalize-entries tail (cons (normalize-entry doc) acc)))
    (_ '#(error invalid_ldoc))))

(defun normalize-entry (doc)
  (case doc
    (`#(doc function ,exported #(,name ,arity) ,patterns ,lines ,line)
     (let* ((kind #b("function"))
            (name-binary (atom_to_binary name 'utf8))
            (entry-arity arity))
       `#m(kind ,kind
            name ,name-binary
            arity ,entry-arity
            annotation ,(erl_anno:new line)
            signatures ()
            doc ,(normalized-doc lines)
            patterns ,patterns
            metadata #m(legacy_doc_lines ,lines
                        legacy_exported ,exported)
            visibility ,(entry-visibility exported))))
    (`#(doc macro ,exported ,name ,patterns ,lines ,line)
     (let* ((kind #b("macro"))
            (name-binary (atom_to_binary name 'utf8))
            (entry-arity 'unknown))
       `#m(kind ,kind
            name ,name-binary
            arity ,entry-arity
            annotation ,(erl_anno:new line)
            signatures ()
            doc ,(normalized-doc lines)
            patterns ,patterns
            metadata #m(legacy_doc_lines ,lines
                        legacy_exported ,exported)
            visibility ,(entry-visibility exported))))))

(defun normalized-doc (lines)
  (case lines
    (() 'none)
    (_ `#m(#b("und") ,(join-lines lines)))))

(defun join-lines (lines)
  (iolist_to_binary (lists:join #b("\n") lines)))

(defun entry-visibility (exported)
  (if exported 'candidate 'internal))

(defun entry-key (entry)
  `#(,(maps:get 'kind entry)
     ,(maps:get 'name entry)
     ,(maps:get 'arity entry)))

(defun unique-entries? (entries)
  (unique-entries? entries 'undefined))
(defun unique-entries? (entries previous)
  (case entries
    (() 'true)
    ((cons entry tail)
     (let ((key (entry-key entry)))
       (if (=:= key previous)
           'false
           (unique-entries? tail key))))))
