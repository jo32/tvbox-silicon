# Generic HTML sources (`csp_GenericHTML`)

A configuration-driven spider for sites that serve plain HTML instead of a TVBox JSON API. It lets a viewer add a source whose pages are scraped with CSS selectors, without shipping a per-site JavaScript or JAR plugin. It runs on the in-process QuickJS runtime on macOS, iOS and tvOS.

This addresses requests such as issue #1223 (HTML sources). It is a generic reader: a source's selectors must be supplied by whoever writes the subscription. It cannot auto-detect an arbitrary site's structure.

## Adding a source

Add one entry to any TVBox subscription:

```json
{
  "key": "my-html",
  "name": "My HTML source",
  "type": 3,
  "api": "csp_GenericHTML",
  "ext": "{ ...configuration JSON as a string... }"
}
```

`api: csp_GenericHTML` routes to the bundled `GenericHTML.js` port via `sites/index.json`. The `ext` string is the configuration and reaches `init(ext)` unchanged (it starts with `{`, so the runtime keeps it as JSON).

## Configuration

`ext` is a JSON object (written as a string). Keys:

| Key | Meaning |
|---|---|
| `url` | Site root, must start with `http(s)`. Required. |
| `encoding` | Response charset, e.g. `utf-8`, `gbk`. Default `utf-8`. |
| `header` / `headers` | Extra request headers. `@base` expands to the site root. |
| `class` | How to read home-page categories (selector + `id`/`name` field rules). |
| `list` | How to read video cards (`selector` + `fields`). |
| `categoryUrl` | Template for a category page. `{id}`, `{pg}`, `{base}`. |
| `detailUrl` | Template for a detail page. `{id}`, `{base}`. |
| `detail` | Detail-page `fields`, plus `playFrom` / `playUrl` for episode lists. |
| `play` | `url` rule that extracts the media link from the detail page. |
| `search` | `url` template for search. `{wd}` is the URL-encoded keyword. |

### Field rules

A field rule is either a selector string (reads trimmed text of the first match) or an object:

| Attribute | Meaning |
|---|---|
| `selector` | Scope inside each item; omit to use the item itself. |
| `attr` | Read an attribute (e.g. `href`, `src`) instead of text. |
| `regex` | Apply a regex and take capture group 1. |
| `tpl` | Substitute the value into a template (`{v}` is the value). |
| `base` | Resolve the value as an absolute URL against `url`. |

`list.fields` values map to TVBox fields: `vod_id`, `vod_name`, `vod_pic`, `vod_remarks`.

### Minimal example

```json
{
  "url": "https://www.example.com",
  "class": {
    "selector": ".nav a",
    "id": { "attr": "href", "regex": "/list/([^.]+)\\.html" },
    "name": {}
  },
  "list": {
    "selector": ".item",
    "fields": {
      "vod_id": { "selector": "a", "attr": "href", "regex": "/play/([^.]+)\\.html", "tpl": "/play/{v}.html", "base": true },
      "vod_name": { "selector": "h3" },
      "vod_pic": { "selector": "img", "attr": "src", "base": true },
      "vod_remarks": { "selector": ".note" }
    }
  },
  "categoryUrl": "/list/{id}.html",
  "detailUrl": "/play/{id}.html",
  "detail": {
    "fields": { "vod_name": { "selector": "h1.title" }, "vod_content": { "selector": ".desc" } },
    "playFrom": { "selector": ".line .title" },
    "playUrl": { "selector": ".line a", "attr": "href", "base": true }
  },
  "play": { "url": { "selector": "video source", "attr": "src" } },
  "search": { "url": "/search?wd={wd}" }
}
```

## Notes

- Duplicate `vod_id` values are dropped; a card without an id or name is skipped.
- Episode groups from `playFrom`/`playUrl` are joined into `vod_play_from` / `vod_play_url` in TVBox `$$$`/`#` form. A single id falls back to the detail URL.
- `play()` re-fetches the detail page with a mobile User-Agent and extracts the media link with the `play.url` rule.
- Sites with server-side rendering are required; pages that build their list purely in client-side JavaScript cannot be scraped.
