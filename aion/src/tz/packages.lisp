;;;; packages.lisp --- the package of aion/tz (#367).

(cl:defpackage #:aion/tz
  (:use #:cl)
  (:documentation
   "Time zones from the system's TZif files (RFC 8536). OFFSET gives a zone's UTC offset at an
    instant, and LOCAL-TO-UNIVERSAL the instant of a wall-clock time, saying when that time
    falls in a daylight-saving gap or overlap. The rules come from $TZDIR, or
    /usr/share/zoneinfo; a deployment needs the tzdata package. PARSE-TZIF and the ZONE-
    functions are pure, so they can be used on any bytes.")
  (:export
   ;; the lookups
   #:offset #:local-to-universal #:valid-zone-p #:zone-names #:find-zone #:*tzdir*
   ;; a zone and the pure functions over it
   #:zone #:zone-p #:zone-name #:zone-footer #:parse-tzif
   #:zone-offset-at #:zone-local-to-universal
   #:parse-posix-tz
   ;; conditions
   #:tz-error #:unknown-zone #:unknown-zone-name #:invalid-zone-name #:invalid-zone-name-name
   #:invalid-tzif #:invalid-tzif-reason))
