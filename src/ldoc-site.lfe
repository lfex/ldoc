;;;; Build a deterministic local reference from exact stored release keys.

(include-lib "kernel/include/file.hrl")

(defmodule ldoc-site
  "Compose exact stored releases into a fresh deterministic local catalogue and
versioned HTML reference tree."
  (export
   (build 3)
   (build 4)))

(defspec (build 3)
  ([(term) (term) (term)]
   (UNION (tuple 'ok (binary)) (tuple 'error (term)))))

(defspec (build 4)
  ([(term) (term) (term) (term)]
   (UNION (tuple 'ok (binary)) (tuple 'error (term)))))

(defun build (store-root releases target)
  "Build a deterministic local site from exact stored RELEASES with default
locale `<<\"en\">>` and return its absolute index path.

TARGET must be a fresh absolute path whose parent already exists. All
release data is prepared before the exclusive target claim; existing targets
are not replaced. Success returns `{ok, IndexPathBinary}` or a tagged error. Catalogue
sorting is bytewise, not semver policy, and metadata routes are opaque
hashes. Only a newly claimed owned target is cleaned after write failure;
cleanup failure preserves both errors. Publication is not an all-files or
power-loss atomic transaction."

  (build store-root releases target #m()))

(defun build (store-root releases target options)
  "Build a fresh site from exact stored releases using the sole site option,
`locale` (a nonempty UTF-8 binary, default `<<\"en\">>`).

Each release spec has an exact `release` map and may declare `overview`,
`source_root`, and `source_base`. Options, store root, absolute fresh target, and
release list are validated; all store/view/render inputs are prepared before
the exclusive target claim. Existing targets are never replaced. Success
returns `{ok, IndexPathBinary}`. Read/render errors carry the exact release and stage;
validation, claim, write, and cleanup failures are tagged. Only the newly
claimed target is eligible for cleanup; cleanup failure retains both errors.
The complete tree is not promised power-loss atomicity."

  (case (validate-request options store-root target releases)
    (`#(error ,reason) `#(error ,reason))
    (`#(ok ,locale ,root ,absolute-target ,specs)
     (case (prepare-site root locale specs)
       (`#(error ,reason) `#(error ,reason))
       (`#(ok ,routes ,files)
        (case (parent-directory? absolute-target)
          ('ok (claim-and-populate absolute-target routes files))
          (`#(error ,reason) `#(error ,reason))))))))

;;;; Pure public-boundary validation. This phase performs no filesystem calls.

(defun validate-request (options store-root target releases)
  (case (validate-options options)
    ('false '#(error invalid_options))
    (locale
     (case (canonical-store-root store-root)
       ('invalid '#(error invalid_store_root))
       (root
        (case (canonical-target target)
          ('invalid '#(error invalid_target))
          (absolute-target
           (case (canonical-releases releases)
             ('invalid '#(error invalid_releases))
             (specs
              (case (duplicate-release specs #m())
                ('none `#(ok ,locale ,root ,absolute-target ,specs))
                (release `#(error #(duplicate_release ,release)))))))))))))

(defun validate-options (options)
  (if (andalso (is_map options)
               (all-keys? (maps:keys options) '(locale))
               (ldoc-html:valid-options? options))
      (maps:get 'locale options #b("en"))
      'false))

(defun all-keys? (keys allowed)
  (case keys
    (() 'true)
    ((cons key rest) (andalso (lists:member key allowed)
                              (all-keys? rest allowed)))
    (_ 'false)))

(defun canonical-store-root (path)
  (case (text-path path)
    (`#(ok ,binary)
     (if (andalso (> (byte_size binary) 0)
                  (not (contains-nul? binary)))
         binary
         'invalid))
    (_ 'invalid)))

(defun canonical-target (path)
  (case (text-path path)
    (`#(ok ,binary)
     (if (andalso (not (contains-nul? binary))
                  (=:= (filename:pathtype binary) 'absolute))
         (canonical-absolute-target (filename:split binary))
         'invalid))
    (_ 'invalid)))

(defun canonical-absolute-target (parts)
  (case parts
    (() 'invalid)
    (_ (if (andalso (not (has-dot-component? parts))
                    (not (=:= (lists:last parts) #b("/"))))
           (let ((canonical (filename:join parts)))
             (if (andalso (> (byte_size canonical) 1)
                          (not (contains-nul? canonical)))
                 canonical
                 'invalid))
           'invalid))))

(defun has-dot-component? (parts)
  (case parts
    (() 'false)
    ((cons part rest)
     (or (or (=:= part #b(".")) (=:= part #b("..")))
         (has-dot-component? rest)))
    (_ 'true)))

(defun text-path (path)
  (if (is_binary path)
      (valid-path-text path)
      (case (andalso (is_list path) (io_lib:char_list path))
        ('true (case (unicode:characters_to_binary path 'utf8 'utf8)
                 (binary (when (is_binary binary)) `#(ok ,binary))
                 (_ 'invalid)))
        (_ 'invalid))))

(defun valid-path-text (path)
  (case (unicode:characters_to_binary path 'utf8 'utf8)
    (binary (when (is_binary binary)) `#(ok ,binary))
    (_ 'invalid)))

(defun contains-nul? (binary)
  (case (binary:match binary #b(0))
    ('nomatch 'false)
    (_ 'true)))

(defun canonical-releases (releases)
  (case (validated-specs releases)
    ('invalid 'invalid)
    (specs (lists:sort #'release-spec-before?/2 specs))))

(defun validated-specs (releases)
  (case releases
    (() 'invalid)
    ((cons spec rest)
     (case (validate-spec spec)
       ('invalid 'invalid)
       (canonical
        (case (validated-specs-tail rest)
          ('invalid 'invalid)
          (tail (cons canonical tail))))))
    (_ 'invalid)))

(defun validated-specs-tail (releases)
  (case releases
    (() ())
    ((cons spec rest)
     (case (validate-spec spec)
       ('invalid 'invalid)
       (canonical
        (case (validated-specs-tail rest)
          ('invalid 'invalid)
          (tail (cons canonical tail))))))
    (_ 'invalid)))

(defun validate-spec (spec)
  (if (andalso (is_map spec)
               (maps:is_key 'release spec)
               (all-keys? (maps:keys spec)
                          '(release overview source_root source_base)))
      (let ((release (maps:get 'release spec)))
        (if (andalso (ldoc-docset:valid-release? release)
                     (release-lengths-valid? release)
                     (valid-spec-options spec))
            (canonical-spec spec release)
            'invalid))
      'invalid))

(defun release-lengths-valid? (release)
  (lists:all #'component-length-valid?/1
             (list (maps:get 'namespace release)
                   (maps:get 'package release)
                   (maps:get 'version release))))

(defun component-length-valid? (binary)
  (andalso (is_binary binary)
           (=< (byte_size binary) 4294967295)))

(defun valid-spec-options (spec)
  (andalso (valid-optional-render-option spec 'overview)
           (andalso (valid-optional-render-option spec 'source_base)
                    (valid-optional-analysis-option spec 'source_root))))

(defun valid-optional-render-option (spec key)
  (case (maps:find key spec)
    ('error 'true)
    (`#(ok ,value) (ldoc-html:valid-options? (maps:put key value #m())))))

(defun valid-optional-analysis-option (spec key)
  (case (maps:find key spec)
    ('error 'true)
    (`#(ok ,value)
     (ldoc-analysis:valid-options? (maps:put key value #m())))))

(defun canonical-spec (spec release)
  (let* ((overview (maps:get 'overview spec #b()))
         (base `#m(release ,release
                   overview ,overview
                   route ,(release-route release)))
         (with-root (case (maps:find 'source_root spec)
                      (`#(ok ,value) (maps:put 'source_root value base))
                      (_ base))))
    (case (maps:find 'source_base spec)
      (`#(ok ,value) (maps:put 'source_base value with-root))
      (_ with-root))))

(defun release-spec-before? (left right)
  (< (release-key (maps:get 'release left))
     (release-key (maps:get 'release right))))

(defun release-key (release)
  `#(,(maps:get 'namespace release)
     ,(maps:get 'package release)
     ,(maps:get 'version release)))

(defun duplicate-release (specs seen)
  (case specs
    (() 'none)
    ((cons spec rest)
     (let ((release (maps:get 'release spec)))
       (if (maps:is_key release seen)
           release
           (duplicate-release rest (maps:put release 'true seen)))))
    (_ 'none)))

;;;; Public read/view/render preparation is complete before output ownership.

(defun prepare-site (root locale specs)
  (case (unique-routes? specs #m())
    ('false '#(error path_collision))
    ('true
     (case (prepare-releases root locale specs '())
       (`#(error ,reason) `#(error ,reason))
       (`#(ok ,prepared)
        (let* ((catalogue (catalogue-bytes specs))
               (files (lists:append
                        (cons (list (tuple #b("index.html") catalogue)
                                    (tuple #b("ldoc.css")
                                           (ldoc-html-assets:css)))
                              (lists:map #'prepared-files/1 prepared)))))
          (case (unique-paths? files #m())
            ('true `#(ok ,(release-routes specs) ,(sort-files files)))
            ('false '#(error path_collision)))))))))

(defun unique-routes? (specs seen)
  (case specs
    (() 'true)
    ((cons spec rest)
     (let ((route (maps:get 'route spec)))
       (if (maps:is_key route seen)
           'false
           (unique-routes? rest (maps:put route 'true seen)))))
    (_ 'false)))

(defun prepare-releases (root locale specs reversed)
  (case specs
    (() `#(ok ,(lists:reverse reversed)))
    ((cons spec rest)
     (prepare-release-and-rest root locale spec rest reversed))
    (_ '#(error invalid_releases))))

(defun prepare-release-and-rest (root locale spec rest reversed)
  (case (prepare-release root locale spec)
    (`#(error ,reason) `#(error ,reason))
    (prepared
     (prepare-releases root locale rest (cons prepared reversed)))
    (_ '#(error invalid_releases))))

(defun prepare-release (root locale spec)
  (let* ((release (maps:get 'release spec))
         (source-options (optional-option spec 'source_root)))
    (case (ldoc-store:get root release)
      (`#(error ,reason) `#(error #(release ,release store ,reason)))
      (`#(ok ,docset)
       (case (ldoc-analysis:view docset source-options)
         (`#(error ,reason) `#(error #(release ,release analysis ,reason)))
         (`#(ok ,view)
          (let ((render-options (render-options spec locale)))
            (case (ldoc-html:render view render-options)
              (`#(error ,reason) `#(error #(release ,release render ,reason)))
              (`#(ok ,files)
               `#m(route ,(maps:get 'route spec)
                   files ,(prefix-files (maps:get 'route spec) files)))))))))))

(defun optional-option (spec key)
  (case (maps:find key spec)
    ('error #m())
    (`#(ok ,value) (maps:put key value #m()))))

(defun render-options (spec locale)
  (let* ((base `#m(locale ,locale version_index true))
         (with-overview (case (maps:find 'overview spec)
                          (`#(ok ,value) (maps:put 'overview value base))
                          (_ base))))
    (case (maps:find 'source_base spec)
      (`#(ok ,value) (maps:put 'source_base value with-overview))
      (_ with-overview))))

(defun prefix-files (route files)
  (case files
    (() ())
    ((cons file rest)
     (cons (tuple (filename:join (list route (element 1 file)))
                  (element 2 file))
           (prefix-files route rest)))))

(defun prepared-files (prepared) (maps:get 'files prepared))

(defun release-routes (specs)
  (case specs
    (() ())
    ((cons spec rest)
     (cons (maps:get 'route spec) (release-routes rest)))))

(defun unique-paths? (files seen)
  (case files
    (() 'true)
    ((cons file rest)
     (let ((path (element 1 file)))
       (if (maps:is_key path seen)
           'false
           (unique-paths? rest (maps:put path 'true seen)))))
    (_ 'false)))

(defun sort-files (files)
  (lists:sort (lambda (left right) (< (element 1 left) (element 1 right)))
              files))

;;;; Stable route identity and accessible exact-release catalogue.

(defun release-route (release)
  (let* ((preimage (iolist_to_binary
                     (list (length-prefixed (maps:get 'namespace release))
                           (length-prefixed (maps:get 'package release))
                           (length-prefixed (maps:get 'version release)))))
         (digest (crypto:hash 'sha256 preimage)))
    (iolist_to_binary (list #b("r-")
                            (binary:encode_hex digest 'uppercase)))))

(defun length-prefixed (value)
  (list (uint32-bytes (byte_size value)) value))

(defun uint32-bytes (value)
  (list (div value 16777216)
        (rem (div value 65536) 256)
        (rem (div value 256) 256)
        (rem value 256)))

(defun catalogue-bytes (specs)
  (iolist_to_binary
    (list #b("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Release catalogue · ldoc</title><link rel=\"stylesheet\" href=\"ldoc.css\"></head><body><a class=\"skip\" href=\"#main\">Skip to content</a><header class=\"top\"><span class=\"library\">ldoc</span><span class=\"version\">Release catalogue</span><span class=\"brand-mark\">ldoc</span></header><main id=\"main\" class=\"content\" tabindex=\"-1\"><article class=\"overview-content\"><h1>Release catalogue</h1>")
          (catalogue-groups specs)
          #b("</article></main></body></html>"))))

(defun catalogue-groups (specs)
  (case specs
    (() ())
    (_ (let* ((first (car specs))
              (release (maps:get 'release first))
              (key `#(,(maps:get 'namespace release)
                      ,(maps:get 'package release)))
              (`#(,group ,rest) (take-library-group key specs ())))
         (cons (catalogue-group key group)
               (catalogue-groups rest))))))

(defun take-library-group (key specs reversed)
  (case specs
    (() `#(,(lists:reverse reversed) ()))
    ((cons spec rest)
     (let* ((release (maps:get 'release spec))
            (current `#(,(maps:get 'namespace release)
                        ,(maps:get 'package release))))
       (if (=:= current key)
           (take-library-group key rest (cons spec reversed))
           `#(,(lists:reverse reversed) ,specs))))))

(defun catalogue-group (key specs)
  (list #b("<section class=\"release-group\"><h2>")
        (ldoc-markup:escape (element 1 key))
        #b("/")
        (ldoc-markup:escape (element 2 key))
        #b("</h2><ul class=\"release-list\">")
        (catalogue-versions specs)
        #b("</ul></section>")))

(defun catalogue-versions (specs)
  (case specs
    (() ())
    ((cons spec rest)
     (let* ((release (maps:get 'release spec))
            (version (maps:get 'version release))
            (route (maps:get 'route spec)))
       (cons (list #b("<li><a href=\"") route
                     #b("/index.html\">")
                     (ldoc-markup:escape version)
                     #b("</a></li>"))
             (catalogue-versions rest))))))

;;;; Target ownership starts only after complete successful preparation.

(defun parent-directory? (target)
  (let ((parent (filename:dirname target)))
    (case (file:read_file_info parent)
      (`#(ok ,info)
       (if (=:= (file_info-type info) 'directory)
           'ok
           `#(error #(output parent ,parent enotdir))))
      (`#(error enoent) `#(error #(output parent ,parent enoent)))
      (`#(error ,reason) `#(error #(output parent ,parent ,reason))))))

(defun claim-and-populate (target routes files)
  (case (file:make_dir target)
    ('ok (populate-owned target routes files))
    (`#(error eexist) '#(error output_exists))
    (`#(error ,reason) `#(error #(output mkdir ,target ,reason)))))

(defun populate-owned (target routes files)
  (try
    (case (populate-tree target routes files)
      ('ok `#(ok ,(filename:join (list target #b("index.html")))))
      (`#(error ,original)
       (case (cleanup-owned target)
         ('ok `#(error ,original))
         (`#(error ,cleanup) `#(error #(cleanup_failed ,original ,cleanup))))))
    (catch
     (`#(,class ,reason ,stacktrace)
      (cleanup-ignoring-errors target)
      (erlang:raise class reason stacktrace)))))

(defun populate-tree (target routes files)
  (case (make-release-directories target routes)
    (`#(error ,reason) `#(error ,reason))
    ('ok (write-files target files))))

(defun make-release-directories (target routes)
  (case routes
    (() 'ok)
    ((cons route rest)
     (let ((path (filename:join (list target route))))
       (case (file:make_dir path)
         ('ok (make-release-directories target rest))
         (`#(error ,reason)
          `#(error #(output mkdir_release ,path ,reason))))))))

(defun write-files (target files)
  (case files
    (() 'ok)
    ((cons file rest)
     (let ((path (filename:join (list target (element 1 file)))))
       (case (write-file-exclusive path (element 2 file))
         ('ok (write-files target rest))
         (`#(error ,reason) `#(error ,reason)))))))

(defun write-file-exclusive (path bytes)
  (case (file:open path '(write binary exclusive))
    (`#(error ,reason) `#(error #(output open ,path ,reason)))
    (`#(ok ,fd)
     (try
       (case (file:write fd bytes)
         ('ok
          (case (file:close fd)
            ('ok 'ok)
            (`#(error ,reason) `#(error #(output close ,path ,reason)))))
         (`#(error ,reason) `#(error #(output write ,path ,reason))))
       (after
        (best-effort-close fd))))))

(defun cleanup-owned (target)
  (case (file:del_dir_r target)
    ('ok 'ok)
    (`#(error ,reason) `#(error ,reason))))

(defun cleanup-ignoring-errors (target)
  (try
    (file:del_dir_r target)
    (catch
     (`#(,_class ,_reason ,_stacktrace) 'ok))))

(defun best-effort-close (fd)
  (try
    (file:close fd)
    (catch
     (`#(,_class ,_reason ,_stacktrace) 'ok))))
