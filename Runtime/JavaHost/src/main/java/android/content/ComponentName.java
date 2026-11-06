package android.content;

public final class ComponentName implements Cloneable, Comparable<ComponentName> {
    private final String packageName, className;
    public ComponentName(String packageName, String className) { this.packageName = packageName; this.className = className; }
    public ComponentName(Context context, String className) { this(context.getPackageName(), className); }
    public ComponentName(Context context, Class<?> type) { this(context.getPackageName(), type.getName()); }
    public String getPackageName() { return packageName; }
    public String getClassName() { return className; }
    public String getShortClassName() { return className.startsWith(packageName + ".") ? className.substring(packageName.length()) : className; }
    public String flattenToString() { return packageName + "/" + className; }
    public String flattenToShortString() { return packageName + "/" + getShortClassName(); }
    @Override public int compareTo(ComponentName other) { return flattenToString().compareTo(other.flattenToString()); }
    @Override public boolean equals(Object other) { return other instanceof ComponentName name && name.flattenToString().equals(flattenToString()); }
    @Override public int hashCode() { return flattenToString().hashCode(); }
    @Override public String toString() { return "ComponentInfo{" + flattenToString() + "}"; }
}
