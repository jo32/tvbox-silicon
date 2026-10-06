import android.os.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public class HandlerLifetimeTest {
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        Handler handler = new Handler();
        var field = Handler.class.getDeclaredField("pending"); field.setAccessible(true);
        Map<?, ?> pending = (Map<?, ?>)field.get(handler);
        CountDownLatch done = new CountDownLatch(2000);
        for (int i=0;i<2000;i++) check(handler.post(done::countDown), "Post rejected");
        check(done.await(5,TimeUnit.SECONDS), "Callbacks stalled");
        long end=System.nanoTime()+TimeUnit.SECONDS.toNanos(2);
        while (true) {
            synchronized(pending) { if(pending.isEmpty())break; }
            check(System.nanoTime()<end,"Completed callbacks retained"); Thread.sleep(1);
        }
        AtomicInteger invoked=new AtomicInteger(); Runnable action=invoked::incrementAndGet;
        for(int i=0;i<1000;i++) handler.postDelayed(action,60_000);
        handler.removeCallbacks(action);
        synchronized(pending) { check(pending.isEmpty(),"Cancelled callbacks retained by handler"); }
        var queueField=Looper.class.getDeclaredField("queue");queueField.setAccessible(true);
        var queue=(ScheduledThreadPoolExecutor)queueField.get(Looper.getMainLooper());
        check(queue.getQueue().isEmpty(),"Cancelled futures retained by executor");
        Looper.shutdown();
        check(queue.awaitTermination(2,TimeUnit.SECONDS),"Source callback thread survived shutdown");
        check(!handler.post(action),"Closed source accepted callback");
        check(invoked.get()==0,"Cancelled callback ran");
        System.out.println("HandlerLifetimeTest passed: completion, cancellation, executor cleanup, source shutdown");
    }
}
