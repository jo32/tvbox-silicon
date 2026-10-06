package tvbox.runtime;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import org.json.JSONObject;

/**
 * macOS entry point: the desktop JVM runs as one long-lived child process and serves the same
 * requests iOS and tvOS send to {@link InProcessHost} over JNI, concurrently, so sources share
 * runtimes exactly as they do there. Commands arrive as JSON lines on stdin
 * ({@code {"id": ..., "input": {...}}}); each answer is written atomically to
 * {@code responses/<id>.json} under the directory given as the only argument.
 */
public final class ProcessHost {
    private ProcessHost() {}

    public static void main(String[] args) throws Exception {
        java.security.Security.addProvider(new org.bouncycastle.jce.provider.BouncyCastleProvider());
        // Plugins print freely; stdout belongs to diagnostics, never to the protocol.
        System.setOut(System.err);
        File root = new File(args[0]);
        File responses = new File(root, "responses");
        responses.mkdirs();
        write(new File(root, "ready.json"), new JSONObject().put("ready", true).toString());
        var reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = reader.readLine()) != null) {
            JSONObject command;
            try { command = new JSONObject(line); } catch (Exception malformed) { continue; }
            String id = command.optString("id");
            if (!id.matches("[A-Za-z0-9-]{1,80}")) continue;
            String input = command.getJSONObject("input").toString();
            // Plugin code recurses deeply; give each request the stack the Apple workers have.
            Thread worker = new Thread(null, () -> {
                File response = new File(responses, id + ".json");
                try { write(response, InProcessHost.request(input)); }
                catch (Throwable error) {
                    // The app waits for this file; never leave a request unanswered.
                    error.printStackTrace(System.err);
                    try { write(response, new JSONObject().put("error", "Plugin request failed: " + error).toString()); }
                    catch (Throwable ignored) { }
                }
            }, "Plugin request " + id, 8L << 20);
            worker.setDaemon(true);
            worker.start();
        }
        // stdin closed: the app quit or restarted the host. Spiders may hold non-daemon threads.
        Runtime.getRuntime().halt(0);
    }

    private static void write(File file, String text) throws Exception {
        var temporary = new File(file.getPath() + ".tmp").toPath();
        // Plugin output can hold lone UTF-16 surrogates; getBytes replaces them where writeString throws.
        Files.write(temporary, text.getBytes(StandardCharsets.UTF_8));
        Files.move(temporary, file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    }
}
