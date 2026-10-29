package tvbox.runtime;

import java.io.IOException;
import okhttp3.Call;
import okhttp3.Response;

/**
 * Captures failures even when a spider catches an exception and returns an empty string.
 * State is per thread: concurrent searches each run on their own native worker thread and
 * must not report another source's failure.
 */
public final class HttpDiagnostics {
    private static final class State {
        String host; int status; String networkError; int newCzChallenges; volatile CloudLoginRequired loginRequired; volatile boolean active;
        /** When the request must stop (epoch ms): the app gave up on it or its deadline passed; 0 = never. */
        volatile java.util.concurrent.atomic.AtomicLong stopAt;
        /** The source's session folder, where a sign-in code for the app goes (LoginPrompt). */
        volatile String folder;
        /** When a sign-in through the plugin's code completed and the request should start over (epoch ms); 0 = no. */
        volatile long signedInAt;
        /** The app was shown a sign-in code for this request, so it may sign in on the drive's page instead. */
        volatile boolean prompted;
    }
    private static final ThreadLocal<State> state = ThreadLocal.withInitial(State::new);

    private static final InheritableThreadLocal<State> requestContext = new InheritableThreadLocal<>();
    /** True while OwnDriveSignIn asks the plugin for its own sign-in: the app shows that code itself. */
    private static final ThreadLocal<Boolean> ownSignIn = ThreadLocal.withInitial(() -> false);
    // FTY/standalone runtimes own exactly one serialized source. Their pre-existing executor
    // threads cannot inherit a new request's context, so they can notify its active playback.
    // Shared multi-source runtimes never use this fallback.
    private static volatile boolean singleSource;
    private static volatile State activePlayback;

    public static void singleSourceRuntime(boolean value) { singleSource = value; }
    public static void reset() { endRequest(); state.remove(); }
    public static void beginRequest(boolean playback) { beginRequest(playback, null, null); }
    public static void beginRequest(boolean playback, java.util.concurrent.atomic.AtomicLong stopAt, String folder) {
        reset();
        State current = state.get(); current.active = true; current.stopAt = stopAt; current.folder = folder;
        requestContext.set(current);
        if (singleSource && playback) activePlayback = current;
    }
    public static void endRequest() {
        State current = state.get(); current.active = false;
        if (activePlayback == current) activePlayback = null;
        requestContext.remove();
    }
    private static State loginState() {
        State inherited = requestContext.get();
        if (inherited != null && inherited.active) return inherited;
        State playback = activePlayback;
        return playback != null && playback.active ? playback : state.get();
    }
    /**
     * The CDN request a cloud-drive proxy made for a file: the app streams that address itself,
     * so video bytes never pass through the plugin's per-range download threads.
     */
    public static final class MediaRequest {
        public final String url; public final java.util.Map<String,String> headers; public final long length;
        MediaRequest(String url, java.util.Map<String,String> headers, long length) { this.url = url; this.headers = headers; this.length = length; }
    }
    private static volatile boolean capturingMedia;
    private static volatile MediaRequest capturedMedia;
    public static void captureMedia(boolean on) { capturingMedia = on; if (on) capturedMedia = null; }
    public static MediaRequest capturedMedia() { return capturedMedia; }
    private static final java.util.Set<String> hopHeaders = java.util.Set.of("range", "host", "accept-encoding", "connection", "content-length", "if-range");
    private static void recordMedia(Response response) {
        if (!capturingMedia || response.code() != 206 || capturedMedia != null) return;
        var sent = response.networkResponse() != null ? response.networkResponse().request() : response.request();
        if (sent.header("Range") == null) return;
        var range = response.header("Content-Range");
        var match = range == null ? null : java.util.regex.Pattern.compile("bytes \\d+-\\d+/(\\d+)").matcher(range);
        if (match == null || !match.matches()) return;
        var headers = new java.util.LinkedHashMap<String,String>();
        for (String name : sent.headers().names()) {
            if (!hopHeaders.contains(name.toLowerCase(java.util.Locale.ROOT))) headers.put(name, String.join("; ", sent.headers(name)));
        }
        capturedMedia = new MediaRequest(sent.url().toString(), headers, Long.parseLong(match.group(1)));
    }

    /*
     * sx.jar's Quark proxy answers a range with the request's own headers instead of a Content-Range,
     * so the relay learns the file's size from the first ranged answer its own thread fetched upstream.
     */
    private static final ThreadLocal<long[]> rangeTotal = new ThreadLocal<>();
    public static void watchRangeTotal(boolean on) { if (on) rangeTotal.set(new long[] { -1 }); else rangeTotal.remove(); }
    public static long rangeTotal() { long[] total = rangeTotal.get(); return total == null ? -1 : total[0]; }
    private static void recordRangeTotal(Response response) {
        long[] total = rangeTotal.get();
        if (total == null || total[0] >= 0 || response.code() != 206) return;
        var range = response.header("Content-Range");
        var match = range == null ? null : java.util.regex.Pattern.compile("bytes \\d+-\\d+/(\\d+)").matcher(range);
        if (match != null && match.matches()) total[0] = Long.parseLong(match.group(1));
    }

    /*
     * Some drive proxies download ranges over HttpURLConnection on their own threads (Fish's
     * multi-threaded downloader), not OkHttp. Its request headers can only be read before it
     * connects, so these wrap the first call that connects it.
     */
    public static int responseCode(java.net.URLConnection connection) throws IOException {
        checkpoint();
        var request = connectionRequest(connection);
        int status = ((java.net.HttpURLConnection) connection).getResponseCode();
        if (request != null) recordMedia(connection, request);
        return status;
    }
    public static java.io.InputStream inputStream(java.net.URLConnection connection) throws IOException {
        checkpoint();
        var request = connectionRequest(connection);
        java.io.InputStream body = connection.getInputStream();
        if (request != null) recordMedia(connection, request);
        return body;
    }
    private static java.util.Map<String, java.util.List<String>> connectionRequest(java.net.URLConnection connection) {
        if (!capturingMedia || capturedMedia != null || !(connection instanceof java.net.HttpURLConnection)) return null;
        String host = connection.getURL().getHost();
        if (host.equals("127.0.0.1") || host.equals("localhost") || host.equals("::1")) return null;
        try {
            var request = connection.getRequestProperties();
            return request.keySet().stream().anyMatch(name -> "range".equalsIgnoreCase(name)) ? request : null;
        } catch (IllegalStateException connected) { return null; }
    }
    private static void recordMedia(java.net.URLConnection connection, java.util.Map<String, java.util.List<String>> request) throws IOException {
        if (capturedMedia != null || ((java.net.HttpURLConnection) connection).getResponseCode() != 206) return;
        var range = connection.getHeaderField("Content-Range");
        var match = range == null ? null : java.util.regex.Pattern.compile("bytes \\d+-\\d+/(\\d+)").matcher(range);
        if (match == null || !match.matches()) return;
        var headers = new java.util.LinkedHashMap<String,String>();
        request.forEach((name, values) -> {
            if (name != null && !hopHeaders.contains(name.toLowerCase(java.util.Locale.ROOT))) headers.put(name, String.join("; ", values));
        });
        // getURL() is the address after redirects, the one that answered.
        capturedMedia = new MediaRequest(connection.getURL().toString(), headers, Long.parseLong(match.group(1)));
    }

    public static String host() { return state.get().host; }
    public static void recordStatus(String host, int status) { State current = state.get(); current.host = host; current.status = status; }

    public static Response execute(Call call) throws IOException { return execute(call, false); }
    public static Response executeNewCz(Call call) throws IOException { return execute(call, true); }

    private static Response execute(Call call, boolean newCz) throws IOException {
        String remote = call.request().url().host();
        String path = call.request().url().encodedPath();
        // These Android plugin flows wait for a QR dialog that cannot be shown by this host, then
        // poll forever. Quark and UC go back to the app's own QR login. Baidu and Aliyun keep
        // the plugin's sign-in: the app shows its code (LoginPrompt) while the plugin polls.
        // Swift's own login uses URLSession and never passes through here.
        boolean own = ownSignIn.get();
        String drive = own ? null : qrLoginDrive(remote, path);
        java.nio.file.Path folder = promptFolder();
        boolean prompts = drive != null && (drive.equals("baidu") || drive.equals("aliyun")) && folder != null;
        if (drive != null && !prompts) throw handBack(drive, call);
        boolean creates = prompts && LoginPrompt.creates(drive, path);
        // Scanning takes a while; give the request time for it, once, when the code is made.
        if (creates) extendForSignIn();
        checkpoint();
        boolean local = remote.equals("127.0.0.1") || remote.equals("localhost") || remote.equals("::1");
        if (!local) PreparationProgress.waiting(remote);
        try {
            Response response = call.execute();
            String confirming = own ? null : LoginPrompt.confirmingDrive(remote, path);
            if (confirming != null && folder != null && LoginPrompt.confirms(confirming, path, response)) signedIn(confirming, folder, response);
            if (creates) {
                Response kept = LoginPrompt.capture(drive, response, folder);
                if (kept == null) { response.close(); throw handBack(drive, call); }
                response = kept;
                loginState().prompted = true;
            }
            recordRangeTotal(response);
            if (local) return response;
            System.err.println("SOURCE_HTTP " + response.request().url().host() + response.request().url().encodedPath() + " " + response.code());
            recordMedia(response);
            State current = state.get();
            if (!response.isSuccessful()) {
                current.host = remote; current.status = response.code(); current.networkError = null;
            } else if (remote.equals(current.host)) { current.host = null; current.status = 0; current.networkError = null; }
            // NewCz blindly persists a missing Set-Cookie value and recurses on 403.
            // Allow its normal cookie handshake, but stop an invalid/unbounded retry.
            if (newCz && response.code() == 403 && (++current.newCzChallenges > 2 || response.header("set-cookie") == null)) {
                response.close();
                throw new SourceHTTPException(remote, 403);
            }
            return response;
        } catch (IOException failure) {
            if (!local && !(failure instanceof SourceHTTPException)) {
                State current = state.get();
                current.host = remote; current.status = 0; current.networkError = failure.getClass().getSimpleName();
            }
            throw failure;
        } finally {
            if (!local) PreparationProgress.waiting(null);
        }
    }

    /**
     * The plugin's sign-in went through. It saves the account itself, but its Android dialog code
     * never tells the waiting request, so that request ends shortly after (once the account is
     * written) and the host serves it again from a fresh spider, which reads the saved account.
     */
    private static void signedIn(String drive, java.nio.file.Path folder, Response response) {
        State request = loginState();
        if (!request.active || request.signedInAt > 0) return;
        request.signedInAt = System.currentTimeMillis() + LoginPrompt.settleMillis(drive);
        try { LoginPrompt.signedIn(folder, drive, LoginPrompt.account(drive, response)); } catch (IOException unwritable) { unwritable.printStackTrace(System.err); }
    }

    /** The running request's session folder, or null outside a request the app made. */
    static java.nio.file.Path promptFolder() {
        State current = loginState();
        String folder = current.folder;
        return current.active && folder != null && !folder.isBlank() ? java.nio.file.Path.of(folder) : null;
    }

    private static CloudLoginRequired handBack(String drive, Call call) {
        State request = loginState();
        request.loginRequired = new CloudLoginRequired(drive);
        call.cancel();
        return request.loginRequired;
    }

    /** Moves a running request's deadline out to the sign-in window; a cancelled request stays cancelled. */
    static void extendForSignIn() {
        State current = loginState();
        var stop = current.stopAt;
        if (!current.active || stop == null) return;
        long now = System.currentTimeMillis(), later = now + LoginPrompt.SIGN_IN_MILLIS;
        long at = stop.get();
        if (at > now && at < later) stop.compareAndSet(at, later);
    }

    /** Runs the plugin's own sign-in (OwnDriveSignIn) on this thread with its QR requests left alone. */
    static <T> T ownSignIn(java.util.concurrent.Callable<T> work) throws Exception {
        ownSignIn.set(true);
        try { return work.call(); } finally { ownSignIn.set(false); }
    }

    /** The running request showed the app a sign-in code, so the viewer may sign in on the drive's page instead. */
    static void prompted() { loginState().prompted = true; }

    public static void throwIfLoginRequired() {
        CloudLoginRequired login = loginState().loginRequired;
        if (login != null) throw login;
    }

    /**
     * Where a plugin waits (it sleeps or makes a request), a request the app no longer wants, or
     * one past its deadline, ends here. Plugins poll in loops that wrap everything in
     * catch (Exception); an Error unwinds through them.
     */
    public static void checkpoint() {
        throwIfLoginRequired();
        throwIfStopped();
    }

    public static void throwIfStopped() {
        State current = loginState();
        long signedIn = current.signedInAt;
        // The viewer signed in on the drive's own page in the app (iPhone, iPad) instead of scanning.
        if (current.active && current.prompted && signedIn == 0 && LoginPrompt.signedInByApp(current.folder)) {
            current.signedInAt = signedIn = System.currentTimeMillis();
            System.err.println("PLUGIN_SIGNED_IN_BY_APP " + java.time.LocalTime.now().withNano(0));
        }
        if (current.active && signedIn > 0 && System.currentTimeMillis() >= signedIn) throw new SignedIn();
        var stop = current.stopAt;
        if (!current.active || stop == null) return;
        long at = stop.get();
        if (at > 0 && System.currentTimeMillis() >= at) throw new RequestStopped();
    }

    /** The drive whose Android QR sign-in a plugin request starts, or null. */
    static String qrLoginDrive(String host, String path) {
        if (path.equals("/cas/ajax/getTokenForQrcodeLogin") || path.equals("/cas/ajax/getServiceTicketByQrcodeToken")) {
            return host.equals("uop.quark.cn") ? "quark" : host.equals("api.open.uc.cn") ? "uc" : null;
        }
        return switch (host) {
            case "passport.baidu.com" -> path.equals("/v2/api/getqrcode") || path.equals("/channel/unicast") ? "baidu" : null;
            case "passport.aliyundrive.com" -> path.startsWith("/newlogin/qrcode/") ? "aliyun" : null;
            case "openapi.aliyundrive.com" -> path.startsWith("/oauth/qrcode") ? "aliyun" : null;
            case "open.aliyundrive.com" -> path.equals("/oauth/users/qrcode/authorize") ? "aliyun" : null;
            case "api.extscreen.com" -> path.startsWith("/aliyundrive/qrcode") ? "aliyun" : null;
            default -> path.equals("/cloudisk/api/oauth/authorize/qrcode") ? "aliyun" : null;
        };
    }

    public static void throwIfFailed() throws IOException {
        throwIfLoginRequired();
        State current = state.get();
        if (current.host == null) return;
        if (current.status > 0) throw new SourceHTTPException(current.host, current.status);
        if (current.networkError != null) throw new IOException("Network request to " + current.host + " failed: " + current.networkError);
    }

    /** A host handoff, not a retryable network exception: bypass plugin catch(Exception) retry loops. */
    public static final class CloudLoginRequired extends Error {
        public final String drive;
        CloudLoginRequired(String drive) {
            super(switch (drive) {
                case "quark" -> "Sign in to Quark in the app to play this episode.";
                case "uc" -> "Sign in to UC in the app to play this episode.";
                case "baidu" -> "This line plays from Baidu Netdisk, but its sign-in code could not be read.";
                default -> "This line plays from Aliyun Drive, but its sign-in code could not be read.";
            });
            this.drive = drive;
        }
    }

    /** The plugin's own sign-in completed; the host restarts the source and serves the request again. */
    public static final class SignedIn extends Error {
        SignedIn() { super("Signed in; the source restarts with the saved account."); }
    }

    /** The app gave up on the request, or it ran past its deadline: a host stop, not a plugin error. */
    public static final class RequestStopped extends Error {
        RequestStopped() { super("The source took too long to respond."); }
    }

    public static final class SourceHTTPException extends IOException {
        public final String host;
        public final int status;
        public SourceHTTPException(String host, int status) {
            super("The source " + host + " returned HTTP " + status);
            this.host = host; this.status = status;
        }
    }
}
