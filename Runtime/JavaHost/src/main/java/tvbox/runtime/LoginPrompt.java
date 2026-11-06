package tvbox.runtime;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONObject;

/**
 * Quark, UC, Baidu Netdisk and Aliyun Drive sign-ins happen inside the plugin: it fetches a QR code for an
 * Android dialog this host cannot show, then polls until the code is scanned and saves the account
 * itself. The host reads the code from the plugin's own response and leaves it in the source's
 * session folder as {@code login-prompt.json}, where the app picks it up and shows it. The plugin's
 * request keeps running for {@link #SIGN_IN_MILLIS} meanwhile.
 */
final class LoginPrompt {
    static final long SIGN_IN_MILLIS = 180_000;
    static final String FILE = "login-prompt.json";
    /** Left by the app when the viewer signed in on the drive's own page instead of scanning the code. */
    static final String APP_FILE = "app-signed-in";

    private LoginPrompt() {}

    /**
     * Whether this response completes the sign-in: Baidu's BDUSS login sets the BDUSS cookie;
     * Aliyun's poll reports {@code qrCodeStatus: CONFIRMED}; Quark's and UC's poll gives a service ticket.
     * The body is peeked, never consumed.
     */
    static boolean confirms(String drive, String path, Response response) {
        if (!response.isSuccessful()) return false;
        if (collectsAccount(drive)) {
            try {
                var json = new JSONObject(response.peekBody(256 * 1024).string());
                var members = json.optJSONObject("data") == null ? null : json.getJSONObject("data").optJSONObject("members");
                return json.optInt("status") == 2_000_000 && members != null && !members.optString("service_ticket").isBlank();
            } catch (Exception unreadable) { return false; }
        }
        if (drive.equals("baidu")) {
            return path.equals("/v3/login/main/qrbdusslogin") && response.headers("Set-Cookie").stream().anyMatch(cookie -> cookie.startsWith("BDUSS=") && !cookie.startsWith("BDUSS=;"));
        }
        if (!path.endsWith("/qrcode/query.do")) return false;
        try { return response.peekBody(256 * 1024).string().contains("\"CONFIRMED\""); }
        catch (java.io.IOException unreadable) { return false; }
    }

    /** The drive whose sign-in this request may complete, or null. */
    static String confirmingDrive(String host, String path) {
        if (path.equals("/cas/ajax/getServiceTicketByQrcodeToken")) return host.equals("uop.quark.cn") ? "quark" : host.equals("api.open.uc.cn") ? "uc" : null;
        if (host.equals("passport.baidu.com") && path.equals("/v3/login/main/qrbdusslogin")) return "baidu";
        if (host.equals("passport.aliyundrive.com") && path.endsWith("/qrcode/query.do")) return "aliyun";
        return null;
    }

    /** How long the plugin gets to save the account before its waiting request starts over. */
    static long settleMillis(String drive) { return drive.equals("baidu") || collectsAccount(drive) ? 1_500 : 4_000; }

    /** Quark and UC: the scan only gives a ticket; the account comes from the pages the plugin opens next. */
    static boolean collectsAccount(String drive) { return drive.equals("quark") || drive.equals("uc"); }

    /** Where the drive's account cookies come from. */
    static String cookieDomain(String drive) { return drive.equals("quark") ? "quark.cn" : "uc.cn"; }

    /** Quark's mobile service ticket from {@code /account/mobileinfo}: {@code {"success":true,"data":{"serviceTicket":…}}}. */
    static String mobileTicket(Response response) {
        try {
            var json = new JSONObject(response.peekBody(256 * 1024).string());
            var data = json.optJSONObject("data");
            String ticket = data == null ? "" : data.optString("serviceTicket");
            return json.optBoolean("success") && !ticket.isBlank() ? ticket : null;
        } catch (Exception unreadable) { return null; }
    }

    /**
     * The account as the app keeps it, once complete: the drive's cookies with {@code __pus}, and for Quark the
     * mobile ticket too, which FTY needs with them (CloudDriveBridge.restoreFtyQuarkAccount). Empty until then.
     */
    static java.util.Map<String, String> collectedAccount(String drive, java.util.Map<String, String> cookies, String ticket) {
        if (cookies.getOrDefault("__pus", "").isBlank() || drive.equals("quark") && (ticket == null || ticket.isBlank())) return java.util.Map.of();
        var cookie = new StringBuilder();
        new java.util.TreeMap<>(cookies).forEach((name, value) -> cookie.append(cookie.length() == 0 ? "" : "; ").append(name).append('=').append(value));
        return drive.equals("quark")
            ? java.util.Map.of("quarkCookie", cookie.toString(), "quarkServiceTicket", ticket)
            : java.util.Map.of("ucCookie", cookie.toString());
    }

    /**
     * The account the confirming response carries, as the app stores it: Baidu's cookies
     * ({@code baiduCookie}), Aliyun's refresh token from {@code bizExt} ({@code token}). Empty when unreadable.
     */
    static java.util.Map<String, String> account(String drive, Response response) {
        if (drive.equals("baidu")) {
            var fields = new java.util.TreeMap<String, String>();
            for (String header : response.headers("Set-Cookie")) {
                String pair = header.split(";", 2)[0].trim();
                int split = pair.indexOf('=');
                if (split <= 0) continue;
                String name = pair.substring(0, split), value = pair.substring(split + 1);
                if (java.util.Set.of("BDUSS", "STOKEN", "PTOKEN").contains(name) && !value.isEmpty()) fields.put(name, value);
            }
            if (!fields.containsKey("BDUSS")) return java.util.Map.of();
            var cookie = new StringBuilder();
            fields.forEach((name, value) -> cookie.append(cookie.length() == 0 ? "" : "; ").append(name).append('=').append(value));
            return java.util.Map.of("baiduCookie", cookie.toString());
        }
        try {
            var data = new JSONObject(response.peekBody(256 * 1024).string()).getJSONObject("content").getJSONObject("data");
            String token = aliyunRefreshToken(data.optString("bizExt"));
            return token == null ? java.util.Map.of() : java.util.Map.of("token", token);
        } catch (Exception unreadable) { return java.util.Map.of(); }
    }

    /** bizExt is base64 of JSON whose text may be GBK; only the ASCII refresh token is read. */
    static String aliyunRefreshToken(String bizExt) {
        try {
            String text = new String(java.util.Base64.getDecoder().decode(bizExt), StandardCharsets.ISO_8859_1);
            var match = java.util.regex.Pattern.compile("\"refreshToken\"\\s*:\\s*\"([0-9A-Za-z]+)\"").matcher(text);
            return match.find() ? match.group(1) : null;
        } catch (IllegalArgumentException notBase64) { return null; }
    }

    /** Tells the app the code was scanned (and the account it signed in to), so it can close the code while the video loads. */
    static void signedIn(Path folder, String drive, java.util.Map<String, ?> account) throws java.io.IOException {
        if (folder == null) return;
        var notice = new JSONObject();
        try {
            notice.put("drive", drive).put("time", System.currentTimeMillis()).put("signedIn", true);
            for (var entry : account.entrySet()) notice.put(entry.getKey(), entry.getValue());
        } catch (org.json.JSONException impossible) { throw new java.io.IOException(impossible); }
        Path temporary = folder.resolve(FILE + ".tmp");
        Files.writeString(temporary, notice.toString(), StandardCharsets.UTF_8);
        Files.move(temporary, folder.resolve(FILE), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        System.err.println("PLUGIN_SIGNED_IN " + java.time.LocalTime.now().withNano(0) + " " + drive);
    }

    /**
     * Whether the app signed in for the request waiting in this folder. The app has saved the account,
     * which the fresh spider reads; the marker is used once.
     */
    static boolean signedInByApp(String folder) {
        if (folder == null || folder.isBlank()) return false;
        try { return Files.deleteIfExists(Path.of(folder, APP_FILE)); }
        catch (java.io.IOException | RuntimeException unreadable) { return false; }
    }

    /** Whether a request for this drive and path creates the QR code (rather than polling it). */
    static boolean creates(String drive, String path) {
        if (collectsAccount(drive)) return path.equals("/cas/ajax/getTokenForQrcodeLogin");
        return drive.equals("baidu") ? path.equals("/v2/api/getqrcode") : drive.equals("aliyun") && path.endsWith("/qrcode/generate.do");
    }

    /** The page Quark's or UC's app opens from a code for this sign-in token; the plugin draws the same one. */
    static String scanPage(String drive, String token, String client) {
        String encoded = java.net.URLEncoder.encode(token, StandardCharsets.UTF_8);
        return drive.equals("quark")
            ? "https://su.quark.cn/4_eMHBJ?token=" + encoded + "&client_id=" + (client == null || client.isBlank() ? "532" : client)
                + "&ssb=weblogin&uc_param_str=&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
            : "https://su.uc.cn/1_n0ZCv?token=" + encoded + "&client_id=" + (client == null || client.isBlank() ? "381" : client)
                + "&uc_param_str=&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix";
    }

    /**
     * Publishes the QR code in the plugin's code-creating response and returns the response
     * intact. Returns null when the body holds no code: the caller then hands the sign-in back.
     */
    static Response capture(String drive, Response response, Path folder) throws java.io.IOException {
        ResponseBody body = response.body();
        if (body == null || !response.isSuccessful()) return null;
        var type = body.contentType();
        byte[] bytes = body.bytes();
        String text = new String(bytes, StandardCharsets.UTF_8);
        String image = null, content = null;
        int start = text.indexOf('{'), end = text.lastIndexOf('}');
        if (start >= 0 && end > start) {
            try {
                JSONObject json = new JSONObject(text.substring(start, end + 1));
                if (collectsAccount(drive)) {
                    // {"status":2000000,"data":{"members":{"token":"…"}}}: the plugin draws the code from the token.
                    JSONObject members = json.optJSONObject("data") == null ? null : json.getJSONObject("data").optJSONObject("members");
                    String token = members == null ? "" : members.optString("token");
                    if (!token.isBlank()) content = scanPage(drive, token, response.request().url().queryParameter("client_id"));
                } else if (drive.equals("baidu")) {
                    // JSONP: {"imgurl":"passport.baidu.com/v2/api/qrcode?sign=…","sign":…}
                    String address = json.optString("imgurl");
                    if (!address.isBlank()) image = address.startsWith("http") ? address : "https://" + address;
                } else {
                    // {"content":{"data":{"codeContent":"https://passport.aliyundrive.com/qrcodeCheck.htm?…","t":…,"ck":…}}}
                    JSONObject data = json.optJSONObject("content") == null ? null : json.getJSONObject("content").optJSONObject("data");
                    String code = data == null ? "" : data.optString("codeContent");
                    if (!code.isBlank()) content = code;
                }
            } catch (Exception unreadable) { }
        }
        if (image == null && content == null) return null;
        publish(folder, drive, image, content);
        return response.newBuilder().body(ResponseBody.create(bytes, type)).build();
    }

    static void publish(Path folder, String drive, String image, String content) throws java.io.IOException {
        Files.createDirectories(folder);
        var prompt = new JSONObject();
        try {
            prompt.put("drive", drive).put("time", System.currentTimeMillis()).put("seconds", SIGN_IN_MILLIS / 1000);
            if (image != null) prompt.put("image", image);
            if (content != null) prompt.put("content", content);
        } catch (org.json.JSONException impossible) { throw new java.io.IOException(impossible); }
        Path temporary = folder.resolve(FILE + ".tmp");
        Files.writeString(temporary, prompt.toString(), StandardCharsets.UTF_8);
        Files.move(temporary, folder.resolve(FILE), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        System.err.println("PLUGIN_SIGN_IN " + java.time.LocalTime.now().withNano(0) + " " + drive);
    }
}
