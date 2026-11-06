package android.graphics;

public class Point {
    public int x, y;
    public Point() { }
    public Point(int x, int y) { this.x = x; this.y = y; }
    public Point(Point other) { this(other.x, other.y); }
    public void set(int x, int y) { this.x = x; this.y = y; }
    @Override public boolean equals(Object o) { return o instanceof Point p && p.x == x && p.y == y; }
    @Override public int hashCode() { return x * 31 + y; }
    @Override public String toString() { return "Point(" + x + ", " + y + ")"; }
}
