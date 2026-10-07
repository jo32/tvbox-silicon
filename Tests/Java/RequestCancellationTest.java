import java.lang.reflect.Method;
import java.util.List;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONObject;
import tvbox.runtime.InProcessHost;

public final class RequestCancellationTest {
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }

    public static void main(String[] args) throws Exception {
        // A cancel can reach the host before its request; the request then never opens a plugin.
        check(new JSONObject(InProcessHost.request("{\"command\":\"cancel\",\"request\":\"early\"}")).getBoolean("result"), "Cancel was refused");
        JSONObject answer = new JSONObject(InProcessHost.request("{\"request\":\"early\",\"session\":\"s\",\"cache\":\"/nonexistent\",\"params\":{\"wd\":\"x\"}}"));
        check("cancelled".equals(answer.optString("errorCode")), "Cancelled request still ran: " + answer);

        Class<?> type = Class.forName("tvbox.runtime.OpeningGate");
        var constructor = type.getDeclaredConstructor(); constructor.setAccessible(true);
        Object gate = constructor.newInstance();
        Method enter = type.getDeclaredMethod("enter", boolean.class, AtomicBoolean.class); enter.setAccessible(true);
        Method leave = type.getDeclaredMethod("leave"); leave.setAccessible(true);

        // The viewer's request opens before a search that was already waiting.
        enter.invoke(gate, false, null);
        List<String> order = new CopyOnWriteArrayList<>();
        Thread search = opener(gate, enter, leave, true, null, order, new AtomicReference<>());
        Thread.sleep(100);
        Thread detail = opener(gate, enter, leave, false, null, order, new AtomicReference<>());
        Thread.sleep(100);
        leave.invoke(gate);
        search.join(5000); detail.join(5000);
        check(order.equals(List.of("detail", "search")), "Searches went first: " + order);

        // An abandoned opener stops waiting.
        enter.invoke(gate, false, null);
        AtomicBoolean cancelled = new AtomicBoolean();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread waiting = opener(gate, enter, leave, true, cancelled, new CopyOnWriteArrayList<>(), failure);
        Thread.sleep(100);
        cancelled.set(true);
        waiting.join(2000);
        check(!waiting.isAlive(), "Cancelled opener kept waiting");
        check(failure.get() instanceof CancellationException, "Cancelled opener did not fail with cancellation: " + failure.get());
        leave.invoke(gate);
        System.out.println("RequestCancellationTest passed: early cancel, viewer before searches, abandoned openers stop");
    }

    private static Thread opener(Object gate, Method enter, Method leave, boolean search, AtomicBoolean cancelled,
                                 List<String> order, AtomicReference<Throwable> failure) {
        Thread thread = new Thread(() -> {
            try {
                enter.invoke(gate, search, cancelled);
                order.add(search ? "search" : "detail");
                leave.invoke(gate);
            } catch (java.lang.reflect.InvocationTargetException error) { failure.set(error.getCause()); }
            catch (Exception error) { failure.set(error); }
        });
        thread.start();
        return thread;
    }
}
