;;;; wire.lisp --- what goes over the wire: JSON objects, event streams, and header values

(cl:in-package #:praxeon/mcp)

(defun %object (&rest keys-and-values)
  "A JSON object, as a hash table, from alternating string keys and values."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on keys-and-values by #'cddr
          do (setf (gethash key table) value))
    table))

(defun %get (object &rest path)
  "The value at PATH in OBJECT, a parsed JSON object, or NIL when any step is missing or is
not an object."
  (loop for key in path
        do (setf object (and (hash-table-p object) (gethash key object))))
  object)

(defun %json-null-p (value) (eq value 'null))

;;; --- event streams ---------------------------------------------------------------------

(defun parse-event-stream (text)
  "The data of each event in TEXT, a text/event-stream body, in order. Lines starting with a
colon are comments and are skipped; an event's data lines are joined with newlines; fields
other than data are ignored. An event with no data is dropped."
  (let ((events '()) (data '()))
    (flet ((finish ()
             (when data
               (push (format nil "~{~A~^~%~}" (reverse data)) events)
               (setf data '()))))
      (dolist (raw (uiop:split-string text :separator (string #\Newline)))
        (let ((line (string-right-trim '(#\Return) raw)))
          (cond ((zerop (length line)) (finish))
                ((char= #\: (char line 0)))
                (t (let* ((colon (position #\: line))
                          (field (if colon (subseq line 0 colon) line))
                          (value (if colon (subseq line (1+ colon)) "")))
                     (when (and (plusp (length value)) (char= #\Space (char value 0)))
                       (setf value (subseq value 1)))
                     (when (string= field "data") (push value data)))))))
      (finish))
    (nreverse events)))

;;; --- header values (2026-07-28: Mcp-Name, Mcp-Param-*) ---------------------------------

(defun %plain-header-value-p (string)
  "Whether STRING can go into a header as it is: visible ASCII, spaces and tabs only, no space
or tab at either end, and not in the base64 sentinel form."
  (let ((n (length string)))
    (and (every (lambda (c) (or (<= #x20 (char-code c) #x7E) (char= c #\Tab))) string)
         (or (zerop n)
             (and (not (member (char string 0) '(#\Space #\Tab)))
                  (not (member (char string (1- n)) '(#\Space #\Tab)))))
         (not (and (>= n 10)
                   (string= "=?base64?" string :end2 9)
                   (string= "?=" string :start2 (- n 2)))))))

(defun encode-header-value (string)
  "STRING as a header value: as it is when that is safe, otherwise in the specification's
form =?base64?...?= over its UTF-8 octets."
  (if (%plain-header-value-p string)
      string
      (format nil "=?base64?~A?="
              (cl-base64:usb8-array-to-base64-string
               (sb-ext:string-to-octets string :external-format :utf-8)))))

(defparameter +max-safe-integer+ (1- (expt 2 53))
  "The largest integer an x-mcp-header parameter may carry, JavaScript's safe range.")

(defun %tchar-p (c)
  "Whether C may appear in an HTTP token (RFC 9110). ALPHANUMERICP alone is true for non-ASCII
letters on SBCL, which a header name cannot carry."
  (or (and (< (char-code c) 128) (alphanumericp c)) (find c "!#$%&'*+-.^_`|~")))

(defun %header-param-value (value type)
  "VALUE, a tool argument whose schema TYPE is \"string\", \"integer\" or \"boolean\", as the
string an Mcp-Param header carries, or NIL when it has no header (JSON null).

The conversion follows TYPE, the type the schema declares, not the type the value happens to
have: the model chose the value, and a value of the wrong type would otherwise go out as a
header that does not match the body, or as no header while the body has one. Such a value is
refused, so the model gets an error it can correct. jzon reads JSON false as NIL, so for a
boolean NIL is false, and for a string or an integer NIL is a JSON false, which is refused."
  (flet ((refuse (reason) (error 'header-value-refused :reason reason)))
    (cond ((%json-null-p value) nil)
          ((equal type "boolean")
           (cond ((eq value t) "true")
                 ((null value) "false")
                 (t (refuse "not a boolean, though the tool declares one"))))
          ((equal type "integer")
           (cond ((not (integerp value)) (refuse "not an integer, though the tool declares one"))
                 ((> (abs value) +max-safe-integer+)
                  (refuse "an integer outside the range JavaScript can represent exactly"))
                 (t (princ-to-string value))))
          ((equal type "string")
           (if (stringp value)
               (encode-header-value value)
               (refuse "not a string, though the tool declares one")))
          (t (refuse "of a type a header cannot carry")))))

(define-condition header-value-refused (error)
  ((reason :initarg :reason :reader header-value-refused-reason))
  (:report (lambda (c s) (format s "an x-mcp-header argument is ~A"
                                 (header-value-refused-reason c))))
  (:documentation "A tool argument that must be copied into a header cannot be. The call is
refused before anything is sent."))

(defun x-mcp-header-paths (schema)
  "The x-mcp-header annotations in SCHEMA, a tool's inputSchema, as a list of
\(HEADER-NAME PROPERTY-PATH TYPE), or the keyword :INVALID when an annotation breaks the
specification's rules (2026-07-28, Streamable HTTP, \"Custom Headers from Tool Parameters\").

An annotation must sit on a property reached from the root through `properties' keys alone,
on a string, integer or boolean property; its value must be a non-empty HTTP token; and no two
may be equal ignoring case. A tool with an invalid annotation is left out of the tool list."
  (let ((found '()) (invalid nil))
    (labels ((walk (node path through-properties-only)
               (cond ((hash-table-p node)
                      (multiple-value-bind (name present) (gethash "x-mcp-header" node)
                        (when present
                          (if (and through-properties-only path
                                   (stringp name) (plusp (length name))
                                   (every #'%tchar-p name)
                                   (member (gethash "type" node) '("string" "integer" "boolean")
                                           :test #'equal))
                              (push (list name (reverse path) (gethash "type" node)) found)
                              (setf invalid t))))
                      (maphash (lambda (key value)
                                 (if (and (string= key "properties") (hash-table-p value))
                                     (maphash (lambda (prop sub)
                                                (walk sub (cons prop path) through-properties-only))
                                              value)
                                     (unless (string= key "x-mcp-header")
                                       (walk value path nil))))
                               node))
                     ((vectorp node)
                      (unless (stringp node)
                        (loop for item across node do (walk item path nil)))))))
      (walk schema '() t))
    (cond (invalid :invalid)
          ((/= (length found)
               (length (remove-duplicates found :key #'car :test #'string-equal)))
           :invalid)
          (t (nreverse found)))))

(defun %value-at (arguments path)
  "The value at PATH in ARGUMENTS, and whether it is present."
  (let ((present t))
    (loop for key in path
          do (if (hash-table-p arguments)
                 (multiple-value-setq (arguments present) (gethash key arguments))
                 (setf arguments nil present nil)))
    (values arguments present)))

(defun header-params (paths arguments)
  "The Mcp-Param headers for ARGUMENTS, from PATHS as X-MCP-HEADER-PATHS returns them. A
parameter absent from ARGUMENTS, or null, has no header."
  (loop for (name path type) in paths
        for value = (multiple-value-bind (v present) (%value-at arguments path)
                      (and present (%header-param-value v type)))
        when value collect (cons (format nil "Mcp-Param-~A" name) value)))
