# hyperion/notifications

In-app notifications (#792). An app tells a user about something that happened while they were
elsewhere: a request awaiting their decision, a moderation outcome, a reply.
- `notify` puts the notification in the user's list, sends it by email through the app's own
  function, or both, as the user chose for that kind of notification.
- The bell shows the unread count, and the list shows the notifications, with mark-read and
  mark-all-read.

A notification is stored until it is read and pruned. hyperion/notice (#980) is for messages
about the page the user is on, which are not stored.

The systems are both opt-in:
- `hyperion/notifications`: the record, the store protocol, a memory store, `notify`, the
  components, the router and the prune job. It has no database.
- `hyperion/notifications-db`: the mnemosyne store.

## Kinds and delivery

```lisp
(define-notification-kind :support-reply :default :both
  :label '(:key :app/support-replies))

(notify store user-id :support-reply
        :title '(:key :app/support-reply :args (:ticket 42))
        :link "/tickets/42"
        :group-key "ticket-42")
```

A delivery is `:in-app`, `:email`, `:both` or `:none`. A user's choice is stored per kind
(`delivery-set`, or the delivery form); until they choose, the kind's default applies. An
undeclared kind is refused with `unknown-notification-kind`, so a misspelt kind is never sent
with some default.

**Email is the app's function**, `*notification-email*` or `notify`'s `:email`. It is a function
of the recipient and the notification. hyperion does not depend on hermes, which is a satellite,
so the app calls hermes itself:

```lisp
(setf *notification-email*
      (lambda (recipient n)
        (hermes:deliver *mailer* (hermes:make-email :to (email-of recipient) :from "noreply@example.com"
                                                    :subject (subject-for n) :text (text-for n)))))
```

`notify` stores the in-app item before it sends the email. So when the email fails, the item is
kept, and the failure is logged without the text and signalled as `notification-email-failed`,
with a `continue` restart.

## The record

| Field | Meaning |
|---|---|
| `title`, `body` | Text, or a translation key with arguments, `(:key KEY :args PLIST)`, shown in the viewer's locale. Never HTML. `body` may be NIL. |
| `link` | NIL or a path on the app's own site: it starts with one `/` and holds no backslash or control character. `https://…`, `//…` and `javascript:…` are refused, so a notification cannot send the user off the site. |
| `group-key` | See below. |
| `count` | How many notifications this item stands for. |
| `created-at`, `read-at` | Universal times. `read-at` is NIL while unread. |

**Group key.** A notification with the same group key as one of the recipient's unread items
collapses into it. The item takes the new text, link and time, and its `count` goes up by one,
which the list shows as "2 times". Once the item is read, the next notification with that key
starts a new item at count 1. A notification without a group key never collapses. In the
database, a partial unique index allows one unread item per recipient and key, so two
notifications sent at the same moment still make one item.

## The store

The store protocol is these generics:
- `notification-put`
- `notification-list` (newest first, paged by `:before`)
- `unread-count`
- `mark-read`
- `mark-all-read`
- `prune-notifications`
- `delivery-ref`
- `delivery-set`

Every call that reads or changes an item takes the recipient. A store matches on recipient and
id together, so marking another user's id does nothing.

`make-memory-notification-store` is for tests, and for one process that does not need
notifications to survive a restart. `hyperion/notifications-db:make-db-notification-store`
takes a mnemosyne pool, as session-db does. Its tables come from the app's migrations; see
docs/migrations.md, section 5.

## The bell, the list and the router

```lisp
(router:mount "/notifications"
              (notification-router store :recipient-fn #'signed-in-user-id
                                         :locale-fn #'locale-of))
;; in the page
(notification-bell (unread-count store user-id))
(:div :id "hyperion-notification-panel")
```

**`notification-bell`.** Its accessible name is the whole sentence, "3 unread notifications". A
hidden region with `role="status"` and `aria-live="polite"` holds the same sentence.

It polls every `:poll-seconds`, 60 by default. That is a whole number of seconds, not an htmx
interval string, so htmx cannot misread it (#422). The poll sends the count it shows, and the
route answers 204 while the count is the same, so htmx swaps nothing. When the count changes,
the answer updates the count and the status region out of band, so a screen reader announces
each change once.

**`notification-panel`** goes in `#hyperion-notification-panel`. Every control is a real button
or link, and each POST carries the CSRF token in its header.

**`notification-router`** needs `:recipient-fn`, which reads the app's sign-in from the request
env. A request with no recipient gets 401, and the recipient is never read from the request
itself. Its routes are:
- `/count`
- `/list`
- `/read`
- `/read-all`
- `/delivery`, which serves the form and saves it

The bell and the router are the only parts that know the count is polled. A later version can
push it over SSE without a change to an app's calls.

Text comes from hyperion/i18n under `:notifications/`, in English when a key is missing. The
unread sentence uses the locale's plural forms (`notifications/unread.one`, `.other`, and so
on).

## Retention

```lisp
(aion/schedule:define-job scheduler "prune-notifications"
                          (prune-notifications-job store :read-days 30)
                          :schedule '(:daily (3 0)))
```

The job deletes read items read more than `read-days` ago. With `:unread-days`, it also deletes
unread items older than that. It returns `(:deleted n)` for the run log.
