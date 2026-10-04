package tvbox.runtime;

import java.io.IOException;
import okhttp3.Call;
import okhttp3.Response;

/** Captures failures even when a spider catches an exception and returns an empty string. */
public final class HttpDiagnostics {
    public static volatile String host;
    public static volatile int status;
    private static volatile String networkError;
    private static int newCzChallenges;

    public static void reset() { host = null; status = 0; networkError = null; newCzChallenges = 0; }

    public static Response execute(Call call) throws IOException { return execute(call, false); }
    public static Response executeNewCz(Call call) throws IOException { return execute(call, true); }

    private static Response execute(Call call, boolean newCz) throws IOException {
        String remote = call.request().url().host();
        boolean local = remote.equals("127.0.0.1") || remote.equals("localhost") || remote.equals("::1");
        try {
            Response response = call.execute();
            if (local) return response;
            System.err.println("SOURCE_HTTP " + response.request().url().host() + response.request().url().encodedPath() + " " + response.code());
            if (!response.isSuccessful()) {
                host = remote; status = response.code(); networkError = null;
            } else if (remote.equals(host)) { host = null; status = 0; networkError = null; }
            // NewCz blindly persists a missing Set-Cookie value and recurses on 403.
            // Allow its normal cookie handshake, but stop an invalid/unbounded retry.
            if (newCz && response.code() == 403 && (++newCzChallenges > 2 || response.header("set-cookie") == null)) {
                response.close();
                throw new SourceHTTPException(remote, 403);
            }
            return response;
        } catch (IOException failure) {
            if (!local && !(failure instanceof SourceHTTPException)) {
                host = remote; status = 0; networkError = failure.getClass().getSimpleName();
            }
            throw failure;
        }
    }

    public static void throwIfFailed() throws IOException {
        if (host == null) return;
        if (status > 0) throw new SourceHTTPException(host, status);
        if (networkError != null) throw new IOException("Network request to " + host + " failed: " + networkError);
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
