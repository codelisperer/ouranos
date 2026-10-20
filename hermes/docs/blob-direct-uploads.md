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
   `upload-target-headers` (the headers the client must send exactly, here `Content-Type` and
   `x-amz-acl: private`),
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
   Otherwise move it out of quarantine and record it.

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
- **The object is private, and the client cannot change that.** By default `upload-url` signs
  `x-amz-acl: private` and puts it in `upload-target-headers`, so the browser must send it. A
  provider with object ACLs, such as DigitalOcean Spaces, would otherwise accept a client's unsigned
  `x-amz-acl: public-read` and make the quarantined upload readable by anyone. With the header
  signed, a PUT that sends `public-read` is refused (403 on MinIO), and so is a PUT that leaves the
  header out (400 on MinIO); measured on #796. For a provider that rejects the header, pass
  `:acl :none` and the URL signs no ACL; then the bucket itself must block public ACLs. Any other
  `:acl` value is refused with reason `:bad-acl`.
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

## On the filesystem store

The filesystem store cannot check a signature, so `upload-url` and the multipart calls signal
`blob-unsupported`, as `upload-url` does on any store class that does not implement it. In
development an app catches that and proxies the upload through `put-blob` instead. `read-blob-range`
and `blob-metadata` work on both stores, so the checking step is the same. A store class that does
not implement `read-blob-range` gets a default that reads the range through `get-blob`.

## CORS

A browser upload to a bucket needs a CORS rule on the bucket allowing `PUT` from the app's origin,
with the `Content-Type` and `x-amz-acl` headers. Without one, the browser blocks the request before it reaches the
store, and the app sees only a network error.

- **To set the rule:** `(hermes/blob:put-bucket-cors store "media" :origins '("https://app.example.com"))`.
  `:methods` defaults to `("PUT")`, `:allowed-headers` to `("Content-Type" "x-amz-acl")` and `:max-age-seconds`
  to 3000. It **replaces** the bucket's whole CORS configuration, as the S3 API does, so a bucket that
  needs other rules as well should have them all set together, by whoever owns the bucket.
- **To find out why an upload never arrived:**
  `(hermes/blob:check-bucket-cors store "media" "https://app.example.com")` reads the bucket's rules and
  returns `:allowed`, `:no-cors-configuration`, `:origin-not-allowed`, `:method-not-allowed` or
  `:header-not-allowed`. Pass `:method` and `:headers` when the upload sends something other than a
  `PUT` with `Content-Type` and `x-amz-acl`. A rule set before `x-amz-acl` was signed allows only
  `Content-Type`, and reads as `:header-not-allowed`. `:no-cors-configuration` is also what a missing bucket reads as.

Both use S3's PutBucketCors and GetBucketCors calls, which DigitalOcean Spaces documents as supported.
Neither has been run against a live store yet; the tests check the request each one sends and the
answer each one reads. Neither applies to the filesystem store, which signals `blob-unsupported`.

## Not yet

- **A browser form upload with a POST policy,** which can carry a size range instead of an exact size,
  is not built; the exact signed size covers the case #770 describes.
