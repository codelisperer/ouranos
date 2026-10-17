# Direct uploads from a browser to S3-compatible storage

`hermes/blob` can hand a client a presigned URL that uploads one file straight to S3, DigitalOcean
Spaces or any other S3-compatible store, so the bytes never pass through the app server (#770).
This is for files too large to proxy: a 350 MB video on a small instance is the case that asked
for it. Smaller files can still go through `put-blob`.

## The flow

1. **The client asks the app for an upload,** saying the file's size and type.
2. **The app chooses the key** and asks the store for a URL:

   ```lisp
   (hermes/blob:upload-url store "media" "quarantine/7f3c…/original"
                           :expires-in 900
                           :content-type "video/mp4"
                           :content-length 367001600     ; the size the client declared
                           :max-bytes 400000000)         ; the most this app accepts
   ```

   It returns an `upload-target`: `upload-target-url`, `upload-target-method` (`"PUT"`),
   `upload-target-headers` (the headers the client must send exactly, here `Content-Type`),
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
  URL, so a client cannot store an HTML page under a URL issued for a video.
- **The size is signed.** With `:content-length`, S3 refuses a body of any other length. With
  `:max-bytes`, `upload-url` refuses to sign a declared size over the limit, and refuses to sign
  at all when no size is declared (`blob-upload-refused`, reason `:content-length-required`). A
  single presigned PUT can be held to an exact size but not to a range, so the cap works by
  checking the declared size and then signing exactly that size.
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
  cap, never the URL or its signature. An app should not log it either, and should not store it.

## On the filesystem store

The filesystem store cannot check a signature, so `upload-url` signals `blob-unsupported`. In
development an app catches that and proxies the upload through `put-blob` instead. `read-blob-range`
and `blob-metadata` work on both stores, so the checking step is the same.

## CORS

A browser upload to a bucket needs a CORS rule on the bucket allowing `PUT` from the app's origin,
with the `Content-Type` header. Without one, the browser blocks the request before it reaches the
store, and the app sees only a network error. A helper to set the rule, and a diagnostic for this
case, are the next step of #770.

## Not yet

- **Multipart uploads,** for files over 5 GB and for resuming on a bad connection, are planned on #770.
- **A browser form upload with a POST policy,** which can carry a size range instead of an exact size,
  is not built; the exact signed size covers the case #770 describes.
