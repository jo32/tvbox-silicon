package com.github.catvod.utils;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;

/**
 * FongMi's new spider SDK: {@code Spider.js}. FongMi evaluates the script in its QuickJS module, which the
 * Java host doesn't have, so evaluation fails with a clear error and the spider can fall back.
 */
public final class Js implements AutoCloseable {
    private volatile boolean closed;

    public String eval(String source) throws Exception {
        return eval(source, "{}");
    }

    public String eval(String source, String options) throws Exception {
        try {
            return evalAsync(source, options).get();
        } catch (ExecutionException error) {
            if (error.getCause() instanceof Exception cause) throw cause;
            if (error.getCause() instanceof Error cause) throw cause;
            throw new IllegalStateException(error.getCause());
        }
    }

    public CompletableFuture<String> evalAsync(String source, String options) {
        if (closed) throw new IllegalStateException("Script owner closed");
        return Task.failedFuture(new UnsupportedOperationException("This app can't run the plugin's JavaScript (Spider.js)"));
    }

    @Override public void close() { closed = true; }
}
