# Direct uploads from a browser to S3-compatible storage

`hermes/blob` can hand a client a presigned URL that uploads one file straight to S3, DigitalOcean
Spaces or any other S3-compatible store, so the bytes never pass through the app server (#770).
This is for files too large to proxy: a 350 MB video on a small instance is the case that asked
for it. Smaller files can still go through `put-blob`.

## The flow

1. **The client asks the app for an upload,** saying the file's size and type. The app checks the
   declared type against its own list of the types it accepts before it asks for a URL. Signing
   holds the client to the type the app passes in; it does not decide whether that type is
   acceptable.
2. **The app chooses the key** and asks the store for a URL:

   ```lisp
   (hermes/blob:upload-url store "media" "quarantine/7f3c…/original"
                           :expires-in 900
                           :content-type "video/mp4"
                           :content-length 367001600     ; the size the client declared
                           :max-bytes 400000000)         ; the most this app accepts
   ```

   It returns an `upload-target`: `upload-target-url`, `upload-target-method` (`"PUT"`),
   `upload-target-headers` (the headers the client must send exactly: here `Content-Type`, and
   `x-amz-acl: private` as well on a store made with `:upload-acl :private`),
   `upload-target-expires-in` and `upload-target-content-length`.
3. **The client PUTs the file** to the URL with those headers. The browser sets
   `Content-Length` itself from the body.
4. **The client tells the app the upload finished.** The app then checks it:

   ```lisp
   (let ((meta (hermes/blob:blob-metadata store "media" key)))
     (blob-meta-size meta) (blob-meta-content-type meta) (blob-meta-etag meta))
   (hermes/blob:read-blob-range store "media" key :start 0 :length 16)  ; the magic bytes
   ```

   If the size or the real file type is not what was asked for, delete it with `delete-blob`.
   Otherwise move it out of quarantine with `move-blob` (below) and record it.

## What is enforced, and where

- **The content type is signed.** S3 refuses a PUT whose `Content-Type` differs from the one in the
  URL, so a client cannot store an HTML page under a URL issued for a video. This only binds the
  type the app passed to `upload-url`. If the app passes on whatever type the client declared, the
  client can declare `text/html` and get a valid URL for it, so the app must check the declared
  type against its own allow-list first (step 1). A content type that is empty or contains a
  control character, CR and LF included, is refused (`blob-upload-refused`, reason
  `:bad-content-type`). Surrounding spaces are trimmed, and `upload-target-headers` returns the
  trimmed value, which is the one that was signed.
- **The size is signed.** With `:content-length`, S3 refuses a body of any other length. With
  `:max-bytes`, `upload-url` refuses to sign a declared size over the limit, and refuses to sign
  at all when no size is declared (`blob-upload-refused`, reason `:content-length-required`). A
  single presigned PUT can be held to an exact size but not to a range, so the cap works by
  checking the declared size and then signing exactly that size. A `:max-bytes` or
  `:content-length` that is not a non-negative integer is refused (reasons `:bad-max-bytes` and
  `:bad-content-length`). On S3 a declared size over 5 GiB, the largest single PUT S3 accepts, is
  refused with reason `:too-large-for-single-put`; such a file needs a multipart upload.
- **On a bucket that honours ACLs, set `:upload-acl :private`.** An unsigned header is not
  covered by the signature, so a client can add `x-amz-acl: public-read` to its PUT. On a bucket
  that honours ACLs, that header could make the quarantined upload readable by anyone. Whether
  DigitalOcean Spaces applies such an unsigned header has not been measured yet (#796). An S3
  store made with `:upload-acl :private`, or with `MNEMOSYNE_S3_UPLOAD_ACL=private`, signs
  `x-amz-acl: private` and puts it in `upload-target-headers`, so the browser must send exactly
  that. Measured on MinIO (#796): with the header signed, a PUT that sends `public-read` is refused
  with 403, and a PUT that leaves the header out is refused with 400.

  Which buckets should set it:
  - **`:private`:** buckets that honour ACLs, such as DigitalOcean Spaces and AWS buckets with ACLs
    enabled.
  - **`:none`, the default:** AWS buckets with ACLs disabled, which is the default for a new AWS
    bucket. AWS documents that such a bucket refuses an upload naming any ACL other than
    `bucket-owner-full-control` with 400 `AccessControlListNotSupported`, so signing `private` there
    would refuse every upload. Also Cloudflare R2, which lists `x-amz-acl` as not implemented.

  Any other value for the setting fails when the store is made, with `blob-configuration-error`.
- **The expiry must be from 1 second to 7 days,** SigV4's limit; anything else is
  `blob-upload-refused` with reason `:bad-expiry`.
- **The key is validated** like every other blob operation, so `..` and the other faults in
  `hermes/blob-key` are refused before anything is signed.

## Security notes

- **Keep the expiry short:** a few minutes, long enough to start the upload. A URL is valid until
  it expires, whoever holds it.
- **The server chooses the key, never the client.** Take nothing from the client for the key but an
  id the server itself issued; never a path or a file name.
- **One URL per upload.** Issue a new one for each file, and do not reuse one for retries after the
  first attempt has finished.
- **Upload into a quarantine prefix** and move the blob only after checking its size and first bytes
  (step 4). Until then nothing should serve it.
- **A presigned URL is a credential.** `upload-url` logs the bucket, key, expiry, declared size and
  cap, never the URL or its signature. An `upload-target` prints its method, expiry and size only,
  so printing one in a log line, an error message or a backtrace does not show the URL. An app
  should not log the URL itself either, and should not store it.

## Multipart uploads

A single presigned PUT carries at most 5 GB, and a dropped connection starts it again from the
first byte. A multipart upload sends the file in parts, each with its own URL, so a large file fits
and an interrupted upload resumes from the parts that already arrived.

1. **The app starts the upload:** `(start-multipart-upload store bucket key :content-type "video/mp4")`
   returns an upload id.
2. **For each part, the app issues a URL:**
   `(multipart-part-url store bucket key upload-id part-number :expires-in 900 :content-length size)`.
   Part numbers run from 1 to 10000. The part number and the upload id are signed into the URL, and
   so is the size when given. Every part but the last must be at least 5 MiB, or completing fails.
3. **The client PUTs each part** and keeps the `ETag` header of each response. A browser script can
   read that header only if the bucket's CORS rule exposes it, so set the rule with
   `:expose-headers '("ETag")`. The server can also read the ETags with `list-multipart-parts`.
4. **The app completes the upload** with `(complete-multipart-upload store bucket key upload-id parts)`,
   PARTS being `((1 . etag) (2 . etag) …)`. A complete that S3 answers with an `<Error>` in a 200
   (a part too small, a wrong ETag) signals `blob-backend-error` with the S3 error code as its detail.
5. **Then the app checks the object** as for a single upload: `blob-metadata` and `read-blob-range`.

To resume, `(list-multipart-parts store bucket key upload-id)` returns `((part-number etag size) …)`
for the parts already stored; the client uploads only the missing ones. To give up,
`abort-multipart-upload` frees the parts. **An upload that is neither completed nor aborted keeps its
parts, and the provider bills for them,** so an app should abort what it abandons, and a bucket
lifecycle rule that aborts incomplete uploads after a few days catches the rest.

There is no total size cap on a multipart upload as there is for `upload-url`: the app holds it by
issuing no more part URLs than the size it accepts, each with a signed size, and by checking
`blob-metadata` after completing.

## Leaving quarantine: copy-blob and move-blob

Once an upload is verified, move it to its final key with
`(hermes/blob:move-blob store "media" quarantine-key "media" final-key)`. The bytes do not pass
through the app (#804). On S3 the store copies the object server-side and then deletes the
source; on the filesystem store it renames the file. `copy-blob` takes the same arguments and
leaves the source where it is. Both return the destination's `blob-meta`.

- **What the copy keeps.** By default the content type, the app's metadata and the checksum are
  copied as they are. `:content-type` replaces the type, and `:metadata` replaces the app's
  metadata (checked as `put-blob` checks it, so `sha256` is refused); the checksum is kept
  either way.
- **The ACL.** S3 never copies an object's ACL. A copied object gets the bucket's default ACL,
  unless the store is made with `:upload-acl :private`, in which case the copy is sent with
  `x-amz-acl: private`.
- **Only the object that was verified is copied.** Record `blob-meta-etag` from the
  `blob-metadata` you check, and pass it as `:if-match` to `move-blob` or `copy-blob` (#826). The
  copy then happens only if the source still has that ETag; otherwise it fails with
  `blob-source-changed` (a `blob-backend-error` with status 412, naming the source), nothing is
  copied, and a move deletes nothing. Without `:if-match`, every copy request is still conditional
  on the ETag read at the start of the copy, so a source replaced partway through a copy is caught
  as well. Verify the object again before retrying. Compare ETags as strings and never recompute
  one: S3's ETag is not a content hash for a multipart or KMS-encrypted object. On the filesystem
  store the ETag is the blob's SHA-256 checksum, and a blob stored without a sidecar has none, so
  any `:if-match` fails for it.
- **Large objects.** Above 5 GiB, the most a single S3 copy can carry, the copy is made in parts
  of at least 512 MiB. A part that fails aborts the copy, so no parts are left to be billed.
  Whether DigitalOcean Spaces supports this part copy (UploadPartCopy) has not been measured
  yet; it works on MinIO.
- **A move is not atomic on S3.** If the copy succeeds and deleting the source fails, the
  delete's own condition is signalled, normally `blob-backend-error` naming the source. A delete
  S3 refuses with 403, as for a role without `s3:DeleteObject`, cannot be told from a missing key
  by the delete itself, so the move checks afterwards that the source is gone and otherwise
  signals `blob-backend-error` naming the source. Either way the destination exists and holds the
  blob, and the source is still there. Retrying the move is safe, because a copy overwrites. A
  sweep of the quarantine prefix should expect a source left behind this way.
- **The delete is unconditional.** If the source is replaced between the copy and the delete,
  the newer object is deleted and the older one is at the destination. That is harmless for a
  quarantine prefix only the app writes to, but use `copy-blob` and your own delete for a key
  other writers use.
- **What a copy does not carry.** A copy with the COPY directive keeps the object as it is. A
  copy with `:content-type` or `:metadata` (S3's REPLACE directive), and a multipart copy, set
  only the content type, the app's metadata, the checksum and the ACL setting: Cache-Control,
  Content-Disposition, Content-Encoding, the storage class, server-side encryption settings and
  tags are not carried over.
- **The same location.** A move whose source and destination are the same deletes nothing and
  returns the blob's metadata. A copy to the same location with no changes does the same; with
  `:content-type` or `:metadata` it rewrites them in place.
- **Errors.** A missing source is `blob-not-found` naming the source. A copy S3 refuses with 403
  (a role without `s3:GetObject` or `s3:PutObject`, or a KMS key it may not use), or a missing
  destination bucket, is `blob-backend-error` naming the destination with the detail "copy
  refused (403) or destination bucket missing", because S3 answers both the same way. A source
  that S3 reports without an ETag is `blob-backend-error` naming the source, since the copy could
  not be made conditional on it. A provider that cannot copy server-side answers 501, which is
  `blob-unsupported`; the app then copies through
  `get-blob` and `put-blob`. A store class an app defines itself gets `blob-unsupported` too,
  until it implements `copy-blob`.

## A public copy for a link-preview card

A page's `og:image` has to be a URL a crawler can fetch without cookies and that does not
expire, and `hyperion/page-meta` uses the site's fallback image instead of a presigned URL.
`public-image-url` makes such a URL for an image in a private bucket (#830):

```lisp
(multiple-value-bind (url width height)
    (hermes/blob:public-image-url store "media" final-key public-store "cards")
  ;; Keep URL, WIDTH and HEIGHT in the post's row, and pass them to page-meta as
  ;; :image, :image-width and :image-height.
  ...)
```

- **Where the copy goes.** `public-store` is a second store whose objects anyone may read: an S3
  store made with `:public-base-url`, or a filesystem store with `:base-url`. Give its bucket a
  policy that allows `s3:GetObject` and not `s3:ListBucket`, so the copies cannot be listed. Do
  not open a prefix of the private bucket instead: one mistake in that policy makes members'
  private images public. For a filesystem public store, the web server that serves its directory
  must have directory listing turned off (`autoindex off` in nginx, `Options -Indexes` in Apache),
  for the same reason.
- **Only for public content.** The copy can be read by anyone who has its URL. Call
  `public-image-url` only for an image shown on a page whose `:visibility` is `:public`. Call
  `(hermes/blob:delete-public-images "media" final-key public-store "cards")` when the image is
  deleted, and also when its post goes from public to private or unlisted. A crawler that already
  fetched the image keeps its own copy, and a CDN can serve a deleted copy until its Cache-Control
  max-age runs out.
- **When to call it.** When the image is uploaded or replaced, not on every page view. A call
  reads the original's metadata and lists one directory of the public bucket. If a copy of this
  version is already there, it returns that copy's URL and reads and writes nothing else.
- **What is removed.** Everything but the pixels and what is needed to show them: EXIF (the GPS
  position, the camera's serial number, and a thumbnail that can show the uncropped original), XMP,
  IPTC, comments, PNG text chunks, and any data after the end of the image, where some phones
  append a second image or a video. The colour profile is kept. The EXIF Orientation field is kept
  in a new EXIF block that holds nothing else, so a phone photo is not shown sideways, and the
  width and height returned are as the image is shown. `strip-image-metadata` does this to an
  octet vector, for an app that wants it elsewhere.
- **What is refused.** Only JPEG, PNG and WebP are accepted, judged from the file's bytes. SVG,
  GIF, HEIC, an image over `:max-bytes` (5 MiB by default) and a file whose structure does not
  parse signal `blob-image-refused`, a `blob-unsupported` whose `blob-image-refused-reason` is
  `:unsupported-format`, `:too-large` or `:malformed`, and nothing is written. Fall back to the
  site's image. HEIC is what an iPhone saves by default, so an app that wants preview cards for
  iPhone photos has to convert them to JPEG at upload; that needs an image library, as resizing
  the copy to 1200 by 630 does, and both wait on the maintainer's decision in #846.
- **Keys and versions.** A copy's key is `og/<SHA-256 of bucket/key>/<SHA-256 of the original's
  ETag>-<width>x<height>.<ext>`, so it does not show the private key. When the original changes,
  its ETag changes, the next call writes a new copy under a new key, and deletes the older copies
  of that image. The hash is not keyed with a secret, so anyone who can guess an original's bucket
  and key can compute its directory and check whether a public copy exists. If the app's keys can
  be guessed, for example `avatars/<member id>.jpg`, that tells an outsider which members have a
  public image; give each original's key a random part, such as a UUID, to prevent it.
- **Cache-Control.** The copy is written with `public, max-age=86400` (the variable
  `*public-image-cache-control*`, or the `:cache-control` argument). `put-blob` takes
  `:cache-control` for any object: the S3 store sends it, and the filesystem store accepts it
  and does nothing with it, because whatever serves that directory sets its own headers. A store
  class the app wrote itself receives `:cache-control` and drops it unless its `put-blob` method
  names the argument and passes it on.

## On the filesystem store

The filesystem store cannot check a signature, so `upload-url` and the multipart calls signal
`blob-unsupported`, as `upload-url` does on any store class that does not implement it. In
development an app catches that and proxies the upload through `put-blob` instead. `read-blob-range`
and `blob-metadata` work on both stores, so the checking step is the same. A store class that does
not implement `read-blob-range` gets a default that reads the range through `get-blob`.

## CORS

A browser upload to a bucket needs a CORS rule on the bucket allowing `PUT` from the app's origin,
with the headers in `upload-target-headers`: `Content-Type`, and `x-amz-acl` on a store made with
`:upload-acl :private`. Without one, the browser blocks the request before it reaches the store,
and the app sees only a network error.

- **To set the rule:** `(hermes/blob:put-bucket-cors store "media" :origins '("https://app.example.com"))`.
  `:methods` defaults to `("PUT")`, `:allowed-headers` to `("Content-Type" "x-amz-acl")`, which covers
  both settings, and `:max-age-seconds` to 3000. It **replaces** the bucket's whole CORS configuration, as the S3 API does, so a bucket that
  needs other rules as well should have them all set together, by whoever owns the bucket.
- **To find out why an upload never arrived:**
  `(hermes/blob:check-bucket-cors store "media" "https://app.example.com")` reads the bucket's rules and
  returns `:allowed`, `:no-cors-configuration`, `:origin-not-allowed`, `:method-not-allowed` or
  `:header-not-allowed`. By default it checks a `PUT` with the headers `upload-url` sends on this
  store: `Content-Type`, plus `x-amz-acl` on a store made with `:upload-acl :private`. A rule that
  allows only `Content-Type` reads as `:header-not-allowed` on such a store. Pass `:method` and
  `:headers` to check something else. `:no-cors-configuration` is also what a missing bucket reads
  as.

Both use S3's PutBucketCors and GetBucketCors calls, which DigitalOcean Spaces documents as supported.
Neither has been run against a live store yet; the tests check the request each one sends and the
answer each one reads. Neither applies to the filesystem store, which signals `blob-unsupported`.

## Not yet

- **A browser form upload with a POST policy,** which can carry a size range instead of an exact size,
  is not built; the exact signed size covers the case #770 describes.
