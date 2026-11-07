package android.os;

/** Cancels an operation in progress (FongMi's Download), as on Android. */
public final class CancellationSignal {
    public interface OnCancelListener { void onCancel(); }

    private boolean canceled;
    private OnCancelListener listener;

    public synchronized boolean isCanceled() { return canceled; }

    public void throwIfCanceled() { if (isCanceled()) throw new OperationCanceledException(); }

    public void cancel() {
        OnCancelListener notify;
        synchronized (this) {
            if (canceled) return;
            canceled = true;
            notify = listener;
        }
        if (notify != null) notify.onCancel();
    }

    public void setOnCancelListener(OnCancelListener value) {
        synchronized (this) {
            if (listener == value) return;
            listener = value;
            if (!canceled || value == null) return;
        }
        value.onCancel();
    }
}
