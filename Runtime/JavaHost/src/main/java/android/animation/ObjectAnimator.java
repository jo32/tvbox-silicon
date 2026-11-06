package android.animation;

import java.lang.reflect.Method;

/** Animates a property of an object (a view's "alpha", "translationY"...) through its setter, as Android does. */
public final class ObjectAnimator extends ValueAnimator {
    private Object target;
    private String property;

    public ObjectAnimator() { }
    private ObjectAnimator(Object target, String property) { this.target = target; this.property = property; }
    public static ObjectAnimator ofFloat(Object target, String property, float... values) { ObjectAnimator a = new ObjectAnimator(target, property); a.setFloatValues(values); return a; }
    public static ObjectAnimator ofInt(Object target, String property, int... values) { ObjectAnimator a = new ObjectAnimator(target, property); a.setIntValues(values); return a; }
    public static ObjectAnimator ofArgb(Object target, String property, int... values) { ObjectAnimator a = ofInt(target, property, values); a.setEvaluator(new ArgbEvaluator()); return a; }
    public static ObjectAnimator ofObject(Object target, String property, TypeEvaluator evaluator, Object... values) {
        ObjectAnimator a = new ObjectAnimator(target, property); a.setObjectValues(values); a.setEvaluator(evaluator); return a;
    }
    @Override public ObjectAnimator setDuration(long duration) { super.setDuration(duration); return this; }
    @Override public void setTarget(Object value) { target = value; }
    public Object getTarget() { return target; }
    public void setPropertyName(String value) { property = value; }
    public String getPropertyName() { return property; }
    public void setAutoCancel(boolean cancel) { }

    @Override void apply(float value) {
        super.apply(value);
        if (target == null || property == null || property.isEmpty()) return;
        Object animated = getAnimatedValue();
        if (animated == null) return;
        String setter = "set" + Character.toUpperCase(property.charAt(0)) + property.substring(1);
        for (Class<?> c = target.getClass(); c != null; c = c.getSuperclass()) {
            for (Method method : c.getDeclaredMethods()) {
                if (!method.getName().equals(setter) || method.getParameterCount() != 1) continue;
                Class<?> type = method.getParameterTypes()[0];
                Object argument = type == float.class || type == Float.class ? (Object) ((Number) animated).floatValue()
                    : type == int.class || type == Integer.class ? (Object) ((Number) animated).intValue()
                    : type.isInstance(animated) ? animated : null;
                if (argument == null || !(animated instanceof Number) && !type.isInstance(animated)) continue;
                try { method.setAccessible(true); method.invoke(target, argument); } catch (ReflectiveOperationException | RuntimeException failed) { }
                return;
            }
        }
    }
}
