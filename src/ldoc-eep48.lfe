;;;; Validate and normalize EEP-48 documentation terms.

(defmodule ldoc-eep48
  (export
   (decode 3)))

(defspec (decode 3)
  ([(atom) (map) (binary)]
   (UNION (tuple 'ok (map)) (tuple 'error 'invalid_docs))))

(defun decode (module source chunk-bytes)
  (case (decode-term chunk-bytes)
    (`#(ok ,term)
     (normalize module source term))
    (_ '#(error invalid_docs))))

(defun decode-term (bytes)
  (try
    (case (erlang:binary_to_term bytes '(used))
      (`#(,term ,used)
       (if (=:= used (byte_size bytes))
           `#(ok ,term)
           '#(error trailing_bytes))))
    (catch
      (`#(error badarg ,_)
       '#(error badarg)))))

(defun normalize (module source term)
  (case term
    (`#(docs_v1 ,annotation ,language ,format ,module-doc ,metadata ,docs)
     (if (andalso (is_atom module)
              (valid-annotation? annotation)
              (is_atom language)
              (valid-format? format)
              (valid-doc? module-doc format)
              (valid-metadata? metadata)
              (valid-entries? docs format))
         (case (normalized-entries docs language)
           (`#(ok ,entries)
            (if (unique-entries? entries)
                `#(ok #m(name ,(atom_to_binary module 'utf8)
                          language ,(atom_to_binary language 'utf8)
                          format ,format
                          source ,source
                          annotation ,annotation
                          doc ,module-doc
                          metadata ,metadata
                          entries ,entries))
                '#(error invalid_docs)))
           (_ '#(error invalid_docs)))
         '#(error invalid_docs)))
    (_ '#(error invalid_docs))))

(defun valid-format? (format)
  (andalso (is_binary format) (> (byte_size format) 0)))

(defun valid-metadata? (metadata)
  (andalso (is_map metadata)
       (valid-metadata-keys? (maps:keys metadata))))

(defun valid-metadata-keys? (keys)
  (case keys
    (() 'true)
    ((cons key tail)
     (and (is_atom key) (valid-metadata-keys? tail)))
    (_ 'false)))

(defun valid-annotation? (annotation)
  (erl_anno:is_anno annotation))

(defun valid-doc? (doc format)
  (case doc
    ('none 'true)
    ('hidden 'true)
    (_ (if (is_map doc)
           (valid-doc-pairs (maps:to_list doc) format)
           'false))))

(defun valid-doc-pairs
  (pairs format)
  (case pairs
    (() 'true)
    ((cons pair tail)
     (case pair
       (`#(,locale ,value)
        (and (is_binary locale)
             (valid-doc-value? value format)
             (valid-doc-pairs tail format)))
       (_ 'false)))
    (_ 'false)))

(defun valid-doc-value? (value format)
  (if (is_binary value)
      'true
      (structured-format? format)))

(defun structured-format? (format)
  (case (binary:match format #b("application/erlang+"))
    (`#(0 ,_length) 'true)
    (_ 'false)))

(defun valid-entries? (entries format)
  (valid-entries entries format))

(defun valid-entries
  (entries format)
  (case entries
    (() 'true)
    ((cons entry tail)
     (and (valid-entry? entry format)
          (valid-entries tail format)))
    (_ 'false)))

(defun valid-entry? (entry format)
  (case entry
    (`#(#(,kind ,name ,arity) ,annotation ,signatures ,doc ,metadata)
     (and (is_atom kind)
          (is_atom name)
          (is_integer arity)
          (>= arity 0)
          (valid-annotation? annotation)
          (valid-signatures? signatures)
          (valid-doc? doc format)
          (valid-metadata? metadata)))
    (_ 'false)))

(defun valid-signatures? (signatures)
  (case signatures
    (() 'true)
    ((cons signature tail)
     (and (is_binary signature)
          (valid-signatures? tail)))
    (_ 'false)))

(defun normalized-entries (docs language)
  (case (normalize-entries docs '() language)
    (`#(ok ,entries)
     `#(ok ,(lists:sort (lambda (left right)
                          (< (entry-key left) (entry-key right)))
                        entries)))
    (_ '#(error invalid_docs))))

(defun normalize-entries (docs acc language)
  (case docs
    (() `#(ok ,acc))
    ((cons source-entry tail)
     (normalize-entry source-entry tail acc language))
    (_ '#(error invalid_docs))))

(defun normalize-entry (source-entry tail acc language)
  (let* ((identity (element 1 source-entry))
         (kind (element 1 identity))
         (name (element 2 identity))
         (arity (element 3 identity))
         (annotation (element 2 source-entry))
         (signatures (element 3 source-entry))
         (doc (element 4 source-entry))
         (metadata (element 5 source-entry))
         (kind-binary (atom_to_binary kind 'utf8))
         (name-binary (atom_to_binary name 'utf8))
         (visibility (entry-visibility language kind-binary name-binary arity))
         (entry `#m(kind ,kind-binary
                    name ,name-binary
                    arity ,arity
                    annotation ,annotation
                    signatures ,signatures
                    doc ,doc
                    metadata ,metadata
                    visibility ,visibility)))
    (normalize-entries tail (cons entry acc) language)))

(defun entry-visibility (language kind name arity)
  (if (and (=:= language 'lfe)
           (=:= kind #b("function"))
           (=:= name #b("LFE-EXPAND-EXPORTED-MACRO"))
           (=:= arity 3))
      'internal
      'candidate))

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
