// Adapted from FongMi/TV catvod (GPL-3.0), commit 4512b4c: the host side of FongMi's new spider SDK (#500).
package com.github.catvod.utils;


import java.util.concurrent.Callable;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** Host: FongMi's Task on plain java.util.concurrent (the host has no Guava). */
public class Task {

    // Daemon threads that end when idle: each plugin runtime has its own copy of this class, and a closed
    // runtime must not keep threads (or the JVM) alive.
    private static final ExecutorService executor = pool(5, "Spider task");
    private static final ExecutorService largeExecutor = pool(20, "Spider task");
    private static final ExecutorService serialExecutor = pool(1, "Spider serial task");
    private static final ScheduledExecutorService scheduler = scheduled("Spider scheduler");

    private static java.util.concurrent.ThreadFactory daemon(String name) {
        return runnable -> {
            Thread thread = new Thread(runnable, name);
            thread.setDaemon(true);
            return thread;
        };
    }

    private static ExecutorService pool(int threads, String name) {
        var pool = new java.util.concurrent.ThreadPoolExecutor(threads, threads, 30, TimeUnit.SECONDS, new java.util.concurrent.LinkedBlockingQueue<>(), daemon(name));
        pool.allowCoreThreadTimeOut(true);
        return pool;
    }

    public static ScheduledExecutorService scheduled(String name) {
        var pool = new java.util.concurrent.ScheduledThreadPoolExecutor(1, daemon(name));
        pool.setKeepAliveTime(30, TimeUnit.SECONDS);
        pool.allowCoreThreadTimeOut(true);
        pool.setRemoveOnCancelPolicy(true);
        return pool;
    }

    public static ExecutorService executor() {
        return executor;
    }

    public static ExecutorService largeExecutor() {
        return largeExecutor;
    }

    public static ScheduledExecutorService scheduler() {
        return scheduler;
    }

    public static <T> CompletableFuture<T> failedFuture(Throwable error) {
        CompletableFuture<T> result = new CompletableFuture<>();
        result.completeExceptionally(error);
        return result;
    }

    public static Future<?> submit(Runnable task) {
        return executor.submit(task);
    }

    public static <T> CompletableFuture<T> submit(Callable<T> callable, long timeoutMillis) {
        CompletableFuture<T> result = new CompletableFuture<>();
        CallTimeout timeout = new CallTimeout(timeoutMillis);
        FutureTask<T> task = new FutureTask<>(() -> {
            Runnable restore = timeout.enter();
            try {
                T value = callable.call();
                result.complete(value);
                return value;
            } catch (Throwable error) {
                result.completeExceptionally(error);
                throw error;
            } finally {
                restore.run();
            }
        });
        result.whenComplete((value, error) -> {
            timeout.close();
            if (!task.isDone()) task.cancel(true);
        });
        timeout.start(() -> result.completeExceptionally(new TimeoutException("Task exceeded " + timeoutMillis + " ms")));
        executor.execute(task);
        return result;
    }

    public static Future<?> submitLarge(Runnable task) {
        return largeExecutor.submit(task);
    }

    public static void execute(Runnable task) {
        executor.execute(task);
    }

    public static void executeSerial(Runnable task) {
        serialExecutor.execute(task);
    }

    public static void schedule(Runnable task, long delay, TimeUnit unit) {
        scheduler.schedule(task, delay, unit);
    }
}
