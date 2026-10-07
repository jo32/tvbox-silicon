package tvbox.runtime;

import java.util.concurrent.CancellationException;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Lets one caller at a time open a plugin (runtime start-up or spider init, which can take
 * minutes). What the viewer is waiting on (home, detail, playback) goes before searches that are
 * still waiting, and a request the app abandoned stops waiting instead of opening a plugin nobody
 * wants.
 */
final class OpeningGate {
    private boolean held;
    private int interactiveWaiting;

    /** Waits for the gate; throws CancellationException once {@code cancelled} is set. */
    synchronized void enter(boolean search, AtomicBoolean cancelled) throws InterruptedException {
        if (!search) interactiveWaiting++;
        try {
            while (held || (search && interactiveWaiting > 0)) {
                if (cancelled != null && cancelled.get()) throw new CancellationException("The app no longer needs this request.");
                // Cancellation does not notify this gate; recheck it every quarter second.
                wait(250);
            }
            if (cancelled != null && cancelled.get()) throw new CancellationException("The app no longer needs this request.");
            held = true;
        } finally {
            if (!search) interactiveWaiting--;
        }
    }

    synchronized void leave() {
        held = false;
        notifyAll();
    }

    /** Whether the request is a search; searches yield to everything else. */
    static boolean search(org.json.JSONObject input) {
        var params = input.optJSONObject("params");
        return params != null && params.has("wd");
    }

    /** The request's cancellation flag, set by the app's {@code cancel} command; null when it has none. */
    static AtomicBoolean cancelled(org.json.JSONObject input) {
        return input.opt("cancelled") instanceof AtomicBoolean flag ? flag : null;
    }
}
