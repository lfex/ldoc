;;;; Store immutable, readable snapshots for exact producer release keys.

(defmodule ldoc-store
  (export
   (get 2)
   (put 2)))

(defspec (get 2)
  ([(term) (term)]
   (UNION (tuple 'ok (map)) (tuple 'error (term)))))

(defspec (put 2)
  ([(term) (term)]
   (UNION 'ok (tuple 'error (term)))))

(defun get (root release)
  "Return the native docset stored for RELEASE under ROOT.

  ROOT is a nonempty binary or flat character-list path. Lookup is exact and
  never creates directories. Snapshot contents are parsed as one data form."
  (case (valid-root? root)
    ('false '#(error invalid_store_root))
    ('true
     (case (ldoc-docset:valid-release? release)
       ('false '#(error invalid_release_key))
       ('true (read-final root release))))))

(defun put (root docset)
  "Publish DOCSET immutably under its exact release key.

  Identical retries succeed without rewriting; different native data for an
  existing key returns release_conflict. Publication uses a same-directory
  temporary file and a hard link as the commit point."
  (case (valid-root? root)
    ('false '#(error invalid_store_root))
    ('true
     (case (validate-docset docset)
       ('ok
        (case (encode-snapshot docset)
          (`#(ok ,bytes)
           (let ((release (maps:get 'release docset)))
             (case (read-final root release)
               (`#(ok ,stored) (same-or-conflict release docset stored))
               (`#(error not_found)
                (publish-missing root release docset bytes))
               (error error))))
          (error error)))
       (error error)))))

(defun valid-root? (root)
  (if (is_binary root)
      (> (byte_size root) 0)
      (andalso (is_list root)
               (not (=:= root '()))
               (io_lib:char_list root))))

(defun validate-docset (docset)
  (if (andalso (is_map docset)
               (=:= (maps:size docset) 2)
               (maps:is_key 'release docset)
               (maps:is_key 'modules docset))
      (let ((release (maps:get 'release docset))
            (modules (maps:get 'modules docset)))
        (case (ldoc-docset:valid-release? release)
          ('false '#(error invalid_release_key))
          ('true
           (if (valid-modules? modules)
               (if (supported-literal? docset)
                   'ok
                   '#(error unsupported_snapshot_term))
               '#(error invalid_docset)))))
      '#(error invalid_docset)))

(defun valid-modules? (modules)
  (case modules
    ((cons _ _) (valid-modules-from? modules 'none))
    (_ 'false)))

(defun valid-modules-from? (modules previous)
  (case modules
    (() 'true)
    ((cons module rest)
     (andalso (is_map module)
              (case (maps:find 'name module)
                (`#(ok ,name)
                 (andalso (is_binary name)
                          (> (byte_size name) 0)
                          (or (=:= previous 'none)
                              (< previous name))
                          (valid-modules-from? rest name)))
                (_ 'false))))
    (_ 'false)))

(defun supported-literal? (term)
  (cond
    ((or (is_function term) (is_pid term) (is_port term) (is_reference term))
     'false)
    ((is_map term) (supported-map? (maps:to_list term)))
    ((is_tuple term) (supported-tuple? (tuple_to_list term)))
    ((is_list term) (supported-list? term))
    ('true 'true)))

(defun supported-map? (pairs)
  (case pairs
    (() 'true)
    ((cons `#(,key ,value) rest)
     (andalso (supported-literal? key)
              (supported-literal? value)
              (supported-map? rest)))))

(defun supported-tuple? (values)
  (case values
    (() 'true)
    ((cons value rest)
     (andalso (supported-literal? value)
              (supported-tuple? rest)))))

(defun supported-list? (values)
  (case values
    (() 'true)
    ((cons value rest)
     (andalso (supported-literal? value)
              (supported-literal? rest)))
    (tail (supported-literal? tail))))

(defun contains-special-map? (term)
  (cond
    ((is_map term)
     (or (maps:is_key '__struct__ term)
         (contains-map-pairs? (maps:to_list term))))
    ((is_tuple term) (contains-special-list? (tuple_to_list term)))
    ((is_list term) (contains-special-list? term))
    ('true 'false)))

(defun contains-map-pairs? (pairs)
  (case pairs
    (() 'false)
    ((cons `#(,key ,value) rest)
     (or (contains-special-map? key)
         (contains-special-map? value)
         (contains-map-pairs? rest)))))

(defun contains-special-list? (values)
  (case values
    (() 'false)
    ((cons value rest)
     (or (contains-special-map? value)
         (contains-special-list? rest)))
    (tail (contains-special-map? tail))))

(defun encode-snapshot (docset)
  (let* ((envelope (maps:put 'docset docset
                             #m(format ldoc_snapshot
                                 format_version 1)))
         (printed (if (contains-special-map? envelope)
                      (lfe_io:print1 envelope)
                      (lfe_io:prettyprint1 envelope)))
         (bytes (unicode:characters_to_binary printed)))
    (if (is_binary bytes)
        (case (read-forms bytes)
          (`#(ok (,readback))
           (if (=:= readback envelope)
               `#(ok ,(iolist_to_binary (list bytes 10)))
               '#(error unsupported_snapshot_term)))
          (_ '#(error unsupported_snapshot_term)))
        '#(error unsupported_snapshot_term))))

(defun read-forms (bytes)
  (case (unicode:characters_to_list bytes 'utf8)
    (characters (when (is_list characters))
     (case (lfe_scan:string characters 1)
       (`#(ok ,tokens ,_last-line)
        (if (literal-token-stream? tokens)
            (lfe_io:read_string characters)
            '#(error executable_snapshot_syntax)))
       (_ '#(error invalid_snapshot_syntax))))
    (_ '#(error invalid_utf8))))

(defun literal-token-stream? (tokens)
  (case tokens
    (() 'true)
    ((cons token rest)
     (let ((tag (element 1 token)))
       (cond
         ((=:= tag (list_to_atom "#.")) 'false)
         ((=:= tag (list_to_atom "#B("))
          (case (consume-binary-literal rest)
            (`#(ok ,remaining) (literal-token-stream? remaining))
            (_ 'false)))
         ('true (literal-token-stream? rest)))))
    (_ 'false)))

(defun consume-binary-literal (tokens)
  (case tokens
    ((cons token rest)
     (let ((tag (element 1 token)))
       (cond
         ((=:= tag 'number)
          (let ((value (element 3 token)))
            (if (valid-byte? value)
                (consume-binary-literal rest)
                'error)))
         ((=:= tag (list_to_atom "("))
          (consume-partial-byte rest))
         ((=:= tag (list_to_atom ")"))
          `#(ok ,rest))
         ('true 'error))))
    (_ 'error)))

(defun consume-partial-byte (tokens)
  (case (take-number-token tokens)
    (`#(ok ,value ,rest1)
     (if (andalso (is_integer value) (>= value 0))
         (case (take-tag rest1 (list_to_atom "("))
           (`#(ok ,rest2)
            (case (take-size-symbol rest2)
              (`#(ok ,rest3)
               (case (take-number-token rest3)
                 (`#(ok ,bits ,rest4)
                  (if (andalso (is_integer bits)
                               (>= bits 1)
                               (=< bits 7)
                               (< value (power-of-two bits)))
                      (case (take-tag rest4 (list_to_atom ")"))
                        (`#(ok ,rest5)
                         (case (take-tag rest5 (list_to_atom ")"))
                           (`#(ok ,rest6)
                            (case (take-tag rest6 (list_to_atom ")"))
                              (`#(ok ,rest7) `#(ok ,rest7))
                              (_ 'error)))
                           (_ 'error)))
                        (_ 'error))
                      'error))
                 (_ 'error)))
              (_ 'error)))
           (_ 'error))
         'error))
    (_ 'error)))

(defun valid-byte? (value)
  (andalso (is_integer value) (>= value 0) (=< value 255)))

(defun power-of-two (exponent)
  (if (=:= exponent 0)
      1
      (* 2 (power-of-two (- exponent 1)))))

(defun take-number-token (tokens)
  (case tokens
    ((cons token rest)
     (if (=:= (element 1 token) 'number)
         `#(ok ,(element 3 token) ,rest)
         'error))
    (_ 'error)))

(defun take-tag (tokens expected)
  (case tokens
    ((cons token rest)
     (if (=:= (element 1 token) expected)
         `#(ok ,rest)
         'error))
    (_ 'error)))

(defun take-size-symbol (tokens)
  (case tokens
    ((cons token rest)
     (if (andalso (=:= (element 1 token) 'symbol)
                  (=:= (element 3 token) 'size))
         `#(ok ,rest)
         'error))
    (_ 'error)))

(defun read-final (root release)
  (case (root-status root 'inspect)
    ('ok
     (let ((path (release-path root release)))
       (case (file:read_link_info path)
         (`#(ok ,info)
          (if (=:= (element 3 info) 'regular)
              (case (file:read_file path)
                (`#(ok ,bytes) (decode-snapshot bytes release))
                (`#(error ,reason)
                 `#(error #(store_io read ,path ,reason))))
              '#(error invalid_snapshot)))
         (`#(error enoent) '#(error not_found))
         (`#(error ,reason)
          `#(error #(store_io inspect ,path ,reason))))))
    (error error)))

(defun root-status (root stage)
  (case (file:read_file_info root)
    (`#(ok ,info)
     (if (=:= (element 3 info) 'directory)
         'ok
         `#(error #(store_io ,stage ,root enotdir))))
    (`#(error enoent) 'ok)
    (`#(error ,reason)
     `#(error #(store_io ,stage ,root ,reason)))))

(defun decode-snapshot (bytes expected-release)
  (case (read-forms bytes)
    (`#(ok (,envelope)) (decode-envelope envelope expected-release))
    (_ '#(error invalid_snapshot))))

(defun decode-envelope (envelope expected-release)
  (if (andalso (is_map envelope)
               (maps:is_key 'format envelope)
               (=:= (maps:get 'format envelope) 'ldoc_snapshot)
               (maps:is_key 'format_version envelope)
               (positive-integer? (maps:get 'format_version envelope)))
      (let ((version (maps:get 'format_version envelope)))
        (if (=/= version 1)
            `#(error #(unsupported_snapshot_version ,version))
            (decode-v1-envelope envelope expected-release)))
      '#(error invalid_snapshot)))

(defun positive-integer? (value)
  (andalso (is_integer value) (> value 0)))

(defun decode-v1-envelope (envelope expected-release)
  (if (andalso (=:= (maps:size envelope) 3)
               (maps:is_key 'docset envelope))
      (let ((docset (maps:get 'docset envelope)))
        (if (=:= (validate-docset docset) 'ok)
            (let ((stored-release (maps:get 'release docset)))
              (if (=:= expected-release stored-release)
                  `#(ok ,docset)
                  `#(error #(release_mismatch ,expected-release
                                               ,stored-release))))
            '#(error invalid_snapshot)))
      '#(error invalid_snapshot)))

(defun release-path (root release)
  (let* ((namespace (maps:get 'namespace release))
         (package (maps:get 'package release))
         (version (maps:get 'version release))
         (preimage (iolist_to_binary
                    (list #b("ldoc-release-v1") 0
                          (length-prefix namespace)
                          (length-prefix package)
                          (length-prefix version))))
         (digest (crypto:hash 'sha256 preimage))
         (hex (binary:encode_hex digest 'uppercase)))
    (path-with-child root
                     (if (is_binary root)
                         (iolist_to_binary (list hex ".lfe"))
                         (lists:append (list (binary_to_list hex)
                                             ".lfe"))))))

(defun path-with-child (root child)
  (filename:join root child))

(defun length-prefix (value)
  (let* ((encoded-length (binary:encode_unsigned (byte_size value)))
         (padding (lists:duplicate (- 8 (byte_size encoded-length)) 0)))
    (iolist_to_binary (list padding encoded-length value))))

(defun same-or-conflict (release wanted stored)
  (if (=:= wanted stored)
      'ok
      `#(error #(release_conflict ,release))))

(defun publish-missing (root release docset bytes)
  (case (root-status root 'ensure_root)
    ('ok
     (case (filelib:ensure_dir (path-with-child root
                                                  (empty-child root)))
       ('ok
        (case (create-temp root bytes 0)
          (`#(ok ,temp)
           (try
             (publish-temp temp (release-path root release)
                           release docset)
             (after
              (best-effort-delete temp))))
          (error error)))
       (`#(error ,reason)
        `#(error #(store_io ensure_root ,root ,reason)))))
    (error error)))

(defun empty-child (root)
  (if (is_binary root) #b("placeholder") "placeholder"))

(defun create-temp (root bytes attempts)
  (if (>= attempts 100)
      `#(error #(store_io open_temp ,root eexist))
      (let ((path (temp-path root)))
        (case (file:open path '(write binary exclusive))
          (`#(ok ,fd) (write-temp path fd bytes))
          (`#(error eexist) (create-temp root bytes (+ attempts 1)))
          (`#(error ,reason)
           `#(error #(store_io open_temp ,path ,reason)))))))

(defun temp-path (root)
  (let* ((random (crypto:strong_rand_bytes 16))
         (hex (binary:encode_hex random 'uppercase))
         (unique (integer_to_binary (erlang:unique_integer '(positive monotonic))))
         (tail (if (is_binary root)
                   (iolist_to_binary (list ".ldoc-" hex "-" unique ".tmp"))
                   (lists:concat (list ".ldoc-" (binary_to_list hex) "-"
                                      (binary_to_list unique) ".tmp")))))
    (filename:join root tail)))

(defun write-temp (path fd bytes)
  (try
    (write-temp-body path fd bytes)
    (catch
     (`#(,class ,reason ,stacktrace)
      (best-effort-close fd)
      (best-effort-delete path)
      (erlang:raise class reason stacktrace)))
    (after
     (best-effort-close fd))))

(defun write-temp-body (path fd bytes)
  (case (file:write fd bytes)
    ('ok
     (case (file:sync fd)
       ('ok
        (case (file:close fd)
          ('ok `#(ok ,path))
        (`#(error ,reason)
         (best-effort-delete path)
         `#(error #(store_io close_temp ,path ,reason)))))
      (`#(error ,reason)
       (best-effort-close fd)
       (best-effort-delete path)
       `#(error #(store_io sync_temp ,path ,reason)))))
    (`#(error ,reason)
     (best-effort-close fd)
     (best-effort-delete path)
     `#(error #(store_io write_temp ,path ,reason)))))

(defun publish-temp (temp final release docset)
  (case (file:make_link temp final)
    ('ok 'ok)
    (`#(error eexist)
     (case (read-final (filename:dirname final) release)
       (`#(ok ,stored) (same-or-conflict release docset stored))
       (error error)))
    (`#(error ,reason)
     `#(error #(store_io publish ,final ,reason)))))

(defun best-effort-close (fd)
  (try
    (file:close fd)
    (catch
     (`#(,_class ,_reason ,_stacktrace) 'ok))))

(defun best-effort-delete (path)
  (try
    (file:delete path)
    (catch
     (`#(,_class ,_reason ,_stacktrace) 'ok))))
