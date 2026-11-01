# Official Dandanplay API

The default danmaku service is `https://api.dandanplay.net`. Automatic matching and
manual search use the same signed API client. The AppId's requests are few and shared
by every install, so automatic matching asks Dandanplay last: only when iQIYI and
Tencent Video (through dmku) find no comments, or first when the title already matched
on Dandanplay (one request, waiting up to five seconds). A title Dandanplay doesn't list
is not searched there again for a week, and after Dandanplay reports its limit
(HTTP 429, or `errorCode` 429) automatic matching leaves it alone for an hour. Manual
search still asks it and says when the limit is reached. The old built-in public proxy URL
is migrated to the official service; other custom server URLs remain supported
and never receive the app's authentication headers.

## Private build configuration

On the release Mac, store a JSON object containing `appId` and `appSecret` in
`~/.config/yingxia/dandanplay.json` (directory mode 700, file mode 600). Obtain
these values from the approved application's DevCenter page. Do not commit them.
For another build machine, supply the same file through its private secret store
and set `DANDANPLAY_CONFIG` to its absolute path when building.

`Scripts/embed-dandanplay-config.py` runs for every macOS, iOS and tvOS app build,
including TestFlight archives. It writes `DandanplayCredentials.plist` into the
app resources before signing. No extra flag is required on this configured Mac.
Missing configuration removes any stale bundled credential and emits a build
warning; official requests report missing configuration, while custom servers
and imported comments remain usable.

Requests use `X-AppId`, Unix-seconds `X-Timestamp`, and
`X-Signature = base64(sha256(AppId + Timestamp + Path + AppSecret))`.
The query string is excluded. The secret itself is never sent as a header.
Comment downloads follow HTTPS redirects only within Dandanplay’s domain,
stripping the API authentication headers before using the server-issued CDN URL.
Bundling keeps the secret out of the public repository, but it can still be
extracted from a distributed client. This follows the official build-time secret
injection option: <https://doc.dandanplay.com/open/>.

## Verification

Run `swift test --filter Dandanplay` for authentication and host-isolation checks.
For an explicit live search → episodes → parsed comments check (three API calls):

```sh
DANDANPLAY_LIVE_CONFIG="$HOME/.config/yingxia/dandanplay.json" swift test --filter dandanplayLive
```

The DevCenter quota is shared by all installations using the AppId. Existing
danmaku and mapping caches reduce repeated requests; monitor usage in DevCenter.
