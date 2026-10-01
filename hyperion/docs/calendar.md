# hyperion/calendar

Two Spinneret components and the pure date helpers they need:

- **`month-grid`**: a Monday-first month grid with previous/next month links.
- **`days-strip`**: N consecutive days (default 7) starting from any date. The window
  slides with its start date and is not aligned to Monday, so weekend days carry a class.

The components handle layout only. The caller supplies what goes in each day (`render-day`)
and where days and months link (`href-for-day`, `href-for-month`). Dates are
`"YYYY-MM-DD"` strings and months are `"YYYY-MM"` strings throughout.

The system is `hyperion/calendar` (opt-in), in `hyperion/src/calendar.lisp`. Its stylesheet is
`hyperion/assets/components/calendar.css`, served by `hyperion/assets` (see "The stylesheet"
below). It was contributed for #489 under the MIT licence and adapted to the framework.

## Dependencies

- **Spinneret**: the components write to `spinneret:*html*` through `spinneret:with-html`.
- **hyperion/i18n**: `translate` to look up names, `translation-exists-p` (#490) to decide
  when to fall back to English, `interpolate` to fill in `{month} {year}`, and
  `*translation-source*` (#491) as the default source.
- **aion/tz**: `offset`, used only by `today` when it is given a zone.

## API

Every function that takes a locale also accepts `:source`, a hyperion/i18n translation
source. It defaults to `hyperion/i18n:*translation-source*`, the request's source, which
`hyperion/i18n:wrap-translation-source` binds per request. With no source, the names are
English.

| Function | Arguments | Returns |
|---|---|---|
| `month-name` | `locale n &key source` | The name of month `n` (1–12). |
| `weekday-name` | `locale n &key source` | The short name of weekday `n` (1 = Monday … 7 = Sunday). |
| `month-title` | `locale month &key source` | A heading such as `"March 2027"`. |
| `date-valid-p` | `string` | True when `string` is a real `YYYY-MM-DD` date in the years 1900–9999. |
| `month-valid-p` | `string` | True when `string` is a real `YYYY-MM` month. |
| `days-in-month` | `year month` | 28–31. Accounts for Gregorian leap years. |
| `add-days` | `date n` | The date `n` days later. `n` may be negative. |
| `weekday` | `date` | 1 = Monday … 7 = Sunday (ISO numbering). |
| `weekend-p` | `date` | True on Saturday and Sunday. |
| `month-of` | `date` | The date's month, as `"YYYY-MM"`. |
| `month-step` | `month n` | The month `n` months later. `n` may be negative. |
| `month-dates` | `month` | The 28, 35 or 42 dates the grid shows: whole weeks from Monday to Sunday. |
| `today` | `&key zone` | Today's date in UTC, or in `zone` (an IANA name or an aion/tz zone). |
| `month-grid` | `locale month &key today render-day href-for-day href-for-month source` | `NIL`. Writes HTML. |
| `days-strip` | `locale &key start (count 7) today render-day href-for-day source` | `NIL`. Writes HTML. |

`add-days` and `weekday` signal an `error` when given an invalid date.

### Callbacks

- **`render-day`** is called as `(funcall render-day date)` once for each cell. It runs
  only for the HTML it writes, so it should write through `spinneret:with-html`. Its
  return value is ignored.
- **`href-for-day`** is called as `(funcall href-for-day date)` and must return a URL string.
  - In `month-grid`, the link is stretched over the whole cell and sits behind the day's
    content, so links inside `render-day`'s output still work.
  - In `days-strip`, the whole cell is the link, so `render-day` must not write links of
    its own there.
- **`href-for-month`** is called as `(funcall href-for-month month)` for the previous and the
  next month. Without it, the grid shows only the month's title.

`today` defaults to `(today)`, which is in UTC. A host that knows the viewer's time zone
should pass `:today (today :zone zone)`.

### Example

```lisp
(spinneret:with-html
  (hyperion/calendar:month-grid
   :en "2027-03"
   :today "2027-03-14"
   :href-for-month (lambda (m) (format nil "/calendar?month=~A" m))
   :href-for-day (lambda (d) (format nil "/calendar/~A" d))
   :render-day (lambda (d)
                 (dolist (e (entries-on d))   ; the host's own data
                   (spinneret:with-html
                     (:a :class "cal-item" :href (entry-url e) (entry-title e)))))))
```

## Translation keys

The keys follow hyperion/i18n's flat `:section/key` convention, and they all live in the
`calendar` section. In a JSON dictionary, that means a `"calendar"` object inside each
locale file. The keys use hyphens rather than dots (`month-1`, not `month.1`). hyperion/i18n
splits keys only on `/`, and it uses a `.` suffix for plural categories, so a dotted key
would read as a plural form.

If the source has a key in neither the requested locale nor its default locale, as
`hyperion/i18n:translation-exists-p` answers, the English text below is used. A translation
whose text happens to look like hyperion/i18n's `"[section/key]"` marker is used as it is.

| Key | English default |
|---|---|
| `calendar/month-1` … `calendar/month-12` | January … December |
| `calendar/weekday-1` … `calendar/weekday-7` | Mon, Tue, Wed, Thu, Fri, Sat, Sun |
| `calendar/month-year` | `{month} {year}` |
| `calendar/previous-month` | Previous month (the prev link's `aria-label`) |
| `calendar/next-month` | Next month (the next link's `aria-label`) |

`month-year` exists so that a locale can change the word order, as in `{year}年{month}`.

## CSS classes

| Class | Element |
|---|---|
| `cal` | Wraps the navigation and the grid. |
| `cal-nav`, `cal-nav__prev`, `cal-nav__next`, `cal-nav__title` | The month navigation. |
| `cal-grid` | The 7-column grid. |
| `cal-grid__head`, `cal-grid__head--weekend` | The weekday header cells. |
| `cal-day` | A day cell in the grid. |
| `cal-day--today`, `cal-day--weekend`, `cal-day--outside` | Today, Saturday or Sunday, and a day outside the shown month. |
| `cal-day__open` | The stretched link to the day. |
| `cal-day__num`, `cal-day__body` | The day number, and the container for `render-day`'s output. |
| `cal-item` | Optional. A one-line entry for `render-day` output. Recolor it with `border-left-color`. |
| `cal-strip` | The strip: 7 columns, one column on narrow screens. |
| `cal-strip__day`, `cal-strip__day--today`, `cal-strip__day--weekend` | A day in the strip. |
| `cal-strip__name` | The weekday name and day number at the top of a strip cell. |
| `cal-sr` | Text for screen readers only: each day's full date. |

Colors are custom properties (`--cal-accent`, `--cal-today-bg`, `--cal-weekend-bg` and others)
declared on `.cal` and `.cal-strip`.

The default text colours are at least 4.5:1 against every default background, which
`hyperion/calendar/tests` checks from the file. `days-strip` sets `--cal-strip-count` to its
`count`, so the strip has one column per day.

## Accessibility

- Today's cell has `aria-current="date"`, in the grid and the strip.
- Each day carries its full date, such as "Sun 14 March 2027". It is the day link's
  `aria-label` when there is one, and otherwise hidden text with the class `cal-sr`. The weekday
  headers and the bare day numbers are hidden from screen readers, so nothing is read twice.

## The stylesheet

`hyperion/assets` embeds `calendar.css` in the image and serves it from memory, like the
vendored htmx and Bulma, under the key `:calendar`. Load `hyperion/assets`, mount its routes
(`hyperion/assets:mount`), and link the stylesheet from the page head:

```lisp
(:link :rel "stylesheet" :href (hyperion/assets:url :calendar))
```

The URL carries a fingerprint of the file's bytes, so it changes when the file does and can
be cached for a year. `hyperion/calendar` does not depend on `hyperion/assets`, so an app that
writes its own styles for these classes does not have to load it.

## Open points

The contributed README listed four. Where each stands:

- **A framework-wide current translation source**: resolved by #491. The calendar's own
  variable is gone; it uses `hyperion/i18n:*translation-source*`.
- **Detecting a missing key**: resolved by #490. The calendar asks
  `hyperion/i18n:translation-exists-p` instead of comparing with the marker.
- **Day boundaries**: still the host's job. Dates are calendar days with no time of day, and
  placing a timed entry on the right local day needs the viewer's zone. `aion/tz:offset`
  gives the offset, and `today` takes `:zone`.
- **Not run against a loaded framework**: resolved. `hyperion/calendar/tests` loads the real
  `hyperion/i18n`, `aion/tz` and Spinneret, and reads the components' markup back.

## What was removed from the original

The original had the same two components inside an application. Removed:

- **The entries shown in each day.** The original drew fixed kinds of entries in the cells:
  chips with a time, done/cancelled styling, a "+N more" overflow, and per-day counts.
  That is now `render-day`.
- **Color coding.** Entries were colored by an application category, the grid had a legend,
  and there were color-picker swatches. These were removed. Coloring is left to the host's
  `render-day` markup, which can use `.cal-item` with `border-left-color`.
- **Application routes.** The day and month URLs were hard-coded. They are now
  `href-for-day` and `href-for-month`.
- **Page chrome.** Removed the page heading, tab bars, filter buttons and the
  links to other application pages that surrounded the components.
- **Application dictionary keys.** Month names, weekday names and the navigation labels
  came from application-specific keys. They are now the neutral `calendar/…` keys above.
- **Application CSS classes and theme colors.** These were renamed to the `cal-` classes and
  replaced with custom properties.
- **The weekday convention.** The original used 0 = Monday internally. It is now ISO 1–7,
  so `weekday` matches the key numbering.
