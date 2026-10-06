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
    private static final class State { String host; int status; String networkError; int newCzChallenges; }
    private static final ThreadLocal<State> state = ThreadLocal.withInitial(State::new);

    public static void reset() { state.remove(); }
    public static String host() { return state.get().host; }
    public static void recordStatus(String host, int status) { State current = state.get(); current.host = host; current.status = status; }

    public static Response execute(Call call) throws IOException { return execute(call, false); }
    public static Response executeNewCz(Call call) throws IOException { return execute(call, true); }

    private static Response execute(Call call, boolean newCz) throws IOException {
        String remote = call.request().url().host();
        boolean local = remote.equals("127.0.0.1") || remote.equals("localhost") || remote.equals("::1");
        if (!local) PreparationProgress.waiting(remote);
        try {
            Response response = call.execute();
            if (local) return response;
            System.err.println("SOURCE_HTTP " + response.request().url().host() + response.request().url().encodedPath() + " " + response.code());
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

    public static void throwIfFailed() throws IOException {
        State current = state.get();
        if (current.host == null) return;
        if (current.status > 0) throw new SourceHTTPException(current.host, current.status);
        if (current.networkError != null) throw new IOException("Network request to " + current.host + " failed: " + current.networkError);
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
