package android.text;

/** Text field filters; the app's own text fields apply plugins' limits (TextView ignores them). */
public interface InputFilter {
    CharSequence filter(CharSequence source, int start, int end, Spanned dest, int dstart, int dend);

    class AllCaps implements InputFilter {
        public AllCaps() { }
        @Override public CharSequence filter(CharSequence source, int start, int end, Spanned dest, int dstart, int dend) {
            return source.subSequence(start, end).toString().toUpperCase(java.util.Locale.ROOT);
        }
    }

    class LengthFilter implements InputFilter {
        private final int max;
        public LengthFilter(int max) { this.max = max; }
        public int getMax() { return max; }
        @Override public CharSequence filter(CharSequence source, int start, int end, Spanned dest, int dstart, int dend) {
            int keep = max - (dest.length() - (dend - dstart));
            if (keep <= 0) return "";
            if (keep >= end - start) return null;
            return source.subSequence(start, start + keep);
        }
    }
}
