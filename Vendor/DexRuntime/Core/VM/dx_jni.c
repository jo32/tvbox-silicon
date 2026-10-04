// DexLoom JNI Bridge
// Provides a complete JNIEnv function table backed by DexLoom's VM.
// Native methods get a real-looking JNIEnv they can call into.

#include "../Include/dx_jni.h"
#include "../Include/dx_vm.h"
#include "../Include/dx_log.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define TAG "JNI"

#include "../Include/dx_memory.h"

// ============================================================================
// JNI <-> DexLoom object mapping
// We cast DxObject* directly to/from jobject (both are opaque pointers).
// ============================================================================

jobject dx_jni_wrap_object(DxObject *obj) {
    return (jobject)obj;
}

DxObject *dx_jni_unwrap_object(jobject ref) {
    return (DxObject *)ref;
}

jclass dx_jni_wrap_class(DxClass *cls) {
    return (jclass)cls;
}

DxClass *dx_jni_unwrap_class(jclass ref) {
    return (DxClass *)ref;
}

// ============================================================================
// We store DxVM* in a static so JNI functions can access it.
// This is fine since DexLoom is single-threaded.
// ============================================================================
static DxVM *g_vm = NULL;

// ============================================================================
// Helper: convert JNI class name ("java/lang/String") to descriptor ("Ljava/lang/String;")
// ============================================================================
static char *jni_name_to_descriptor(const char *name) {
    if (!name) return NULL;
    // Already in descriptor form?
    if (name[0] == 'L' || name[0] == '[') return dx_strdup(name);
    size_t len = strlen(name);
    char *desc = (char *)dx_malloc(len + 3);
    if (!desc) return NULL;
    desc[0] = 'L';
    memcpy(desc + 1, name, len);
    desc[len + 1] = ';';
    desc[len + 2] = '\0';
    return desc;
}

// ============================================================================
// JNI function implementations
// ============================================================================

static jint JNICALL jni_GetVersion(JNIEnv *env) {
    (void)env;
    return 0x00010006; // JNI 1.6
}

static jclass JNICALL jni_DefineClass(JNIEnv *env, const char *name,
                                       jobject loader, const jbyte *buf, jsize len) {
    (void)env; (void)name; (void)loader; (void)buf; (void)len;
    DX_WARN(TAG, "DefineClass not supported");
    return NULL;
}

static jclass JNICALL jni_FindClass(JNIEnv *env, const char *name) {
    (void)env;
    if (!g_vm || !name) return NULL;
    char *desc = jni_name_to_descriptor(name);
    if (!desc) return NULL;
    DxClass *cls = NULL;
    dx_vm_load_class(g_vm, desc, &cls);
    dx_free(desc);
    DX_DEBUG(TAG, "FindClass(%s) -> %p", name, (void *)cls);
    return dx_jni_wrap_class(cls);
}

static jmethodID JNICALL jni_FromReflectedMethod(JNIEnv *env, jobject method) {
    (void)env; (void)method;
    return NULL;
}

static jfieldID JNICALL jni_FromReflectedField(JNIEnv *env, jobject field) {
    (void)env; (void)field;
    return NULL;
}

static jobject JNICALL jni_ToReflectedMethod(JNIEnv *env, jclass cls,
                                              jmethodID methodID, jboolean isStatic) {
    (void)env; (void)cls; (void)methodID; (void)isStatic;
    return NULL;
}

static jclass JNICALL jni_GetSuperclass(JNIEnv *env, jclass sub) {
    (void)env;
    DxClass *cls = dx_jni_unwrap_class(sub);
    if (!cls || !cls->super_class) return NULL;
    return dx_jni_wrap_class(cls->super_class);
}

static jboolean JNICALL jni_IsAssignableFrom(JNIEnv *env, jclass sub, jclass sup) {
    (void)env;
    DxClass *sub_cls = dx_jni_unwrap_class(sub);
    DxClass *sup_cls = dx_jni_unwrap_class(sup);
    if (!sub_cls || !sup_cls) return JNI_FALSE;
    DxClass *walk = sub_cls;
    while (walk) {
        if (walk == sup_cls) return JNI_TRUE;
        walk = walk->super_class;
    }
    return JNI_FALSE;
}

static jobject JNICALL jni_ToReflectedField(JNIEnv *env, jclass cls,
                                             jfieldID fieldID, jboolean isStatic) {
    (void)env; (void)cls; (void)fieldID; (void)isStatic;
    return NULL;
}

static jint JNICALL jni_Throw(JNIEnv *env, jthrowable obj) {
    (void)env;
    if (g_vm) {
        g_vm->pending_exception = (DxObject *)obj;
    }
    return 0;
}

static jint JNICALL jni_ThrowNew(JNIEnv *env, jclass clazz, const char *msg) {
    (void)env;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    const char *descriptor = cls ? cls->descriptor : "Ljava/lang/Exception;";
    if (g_vm) {
        DxObject *ex = dx_vm_create_exception(g_vm, descriptor, msg);
        if (ex) {
            g_vm->pending_exception = ex;
        }
    }
    DX_WARN(TAG, "ThrowNew: %s: %s",
             cls ? cls->descriptor : "?", msg ? msg : "(null)");
    return 0;
}

static jthrowable JNICALL jni_ExceptionOccurred(JNIEnv *env) {
    (void)env;
    if (g_vm && g_vm->pending_exception) {
        return (jthrowable)g_vm->pending_exception;
    }
    return NULL;
}

static void JNICALL jni_ExceptionDescribe(JNIEnv *env) {
    (void)env;
    if (g_vm && g_vm->pending_exception) {
        DxObject *ex = g_vm->pending_exception;
        DX_WARN(TAG, "Pending exception: %s",
                 ex->klass ? ex->klass->descriptor : "?");
    }
}

static void JNICALL jni_ExceptionClear(JNIEnv *env) {
    (void)env;
    if (g_vm) {
        g_vm->pending_exception = NULL;
    }
}

static void JNICALL jni_FatalError(JNIEnv *env, const char *msg) {
    (void)env;
    DX_ERROR(TAG, "FatalError: %s", msg ? msg : "(null)");
}

static jint JNICALL jni_PushLocalFrame(JNIEnv *env, jint capacity) {
    (void)env; (void)capacity;
    return 0; // Success
}

static jobject JNICALL jni_PopLocalFrame(JNIEnv *env, jobject result) {
    (void)env;
    return result;
}

static jobject JNICALL jni_NewGlobalRef(JNIEnv *env, jobject lobj) {
    (void)env;
    return lobj; // No ref tracking — just pass through
}

static void JNICALL jni_DeleteGlobalRef(JNIEnv *env, jobject gref) {
    (void)env; (void)gref;
}

static void JNICALL jni_DeleteLocalRef(JNIEnv *env, jobject obj) {
    (void)env; (void)obj;
}

static jboolean JNICALL jni_IsSameObject(JNIEnv *env, jobject obj1, jobject obj2) {
    (void)env;
    return obj1 == obj2 ? JNI_TRUE : JNI_FALSE;
}

static jobject JNICALL jni_NewLocalRef(JNIEnv *env, jobject ref) {
    (void)env;
    return ref;
}

static jint JNICALL jni_EnsureLocalCapacity(JNIEnv *env, jint capacity) {
    (void)env; (void)capacity;
    return 0;
}

static jobject JNICALL jni_AllocObject(JNIEnv *env, jclass clazz) {
    (void)env;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    if (!cls || !g_vm) return NULL;
    DxObject *obj = dx_vm_alloc_object(g_vm, cls);
    return dx_jni_wrap_object(obj);
}

static jobject JNICALL jni_NewObject(JNIEnv *env, jclass clazz, jmethodID methodID, ...) {
    (void)env;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    if (!cls || !g_vm) return NULL;
    DxObject *obj = dx_vm_alloc_object(g_vm, cls);
    if (obj && methodID) {
        DxMethod *init = (DxMethod *)methodID;
        DxValue args[1] = { {.tag = DX_VAL_OBJ, .obj = obj} };
        g_vm->insn_count = 0;
        dx_vm_execute_method(g_vm, init, args, 1, NULL);
    }
    return dx_jni_wrap_object(obj);
}

static jobject JNICALL jni_NewObjectV(JNIEnv *env, jclass clazz, jmethodID methodID, va_list args) {
    (void)env; (void)methodID; (void)args;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    if (!cls || !g_vm) return NULL;
    DxObject *obj = dx_vm_alloc_object(g_vm, cls);
    return dx_jni_wrap_object(obj);
}

static jobject JNICALL jni_NewObjectA(JNIEnv *env, jclass clazz, jmethodID methodID, const jvalue *args) {
    (void)env; (void)methodID; (void)args;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    if (!cls || !g_vm) return NULL;
    DxObject *obj = dx_vm_alloc_object(g_vm, cls);
    return dx_jni_wrap_object(obj);
}

static jclass JNICALL jni_GetObjectClass(JNIEnv *env, jobject obj) {
    (void)env;
    DxObject *dobj = dx_jni_unwrap_object(obj);
    if (!dobj || !dobj->klass) return NULL;
    return dx_jni_wrap_class(dobj->klass);
}

static jboolean JNICALL jni_IsInstanceOf(JNIEnv *env, jobject obj, jclass clazz) {
    (void)env;
    DxObject *dobj = dx_jni_unwrap_object(obj);
    DxClass *target = dx_jni_unwrap_class(clazz);
    if (!dobj || !target) return JNI_FALSE;
    DxClass *walk = dobj->klass;
    while (walk) {
        if (walk == target) return JNI_TRUE;
        walk = walk->super_class;
    }
    return JNI_FALSE;
}

static jmethodID JNICALL jni_GetMethodID(JNIEnv *env, jclass clazz,
                                          const char *name, const char *sig) {
    (void)env; (void)sig;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    if (!cls || !name) return NULL;
    DxMethod *m = dx_vm_find_method(cls, name, NULL);
    return (jmethodID)m;
}

// Call<Type>Method stubs — these call through to DexLoom's VM
static jobject JNICALL jni_CallObjectMethod(JNIEnv *env, jobject obj, jmethodID methodID, ...) {
    (void)env;
    DxMethod *m = (DxMethod *)methodID;
    DxObject *dobj = dx_jni_unwrap_object(obj);
    if (!m || !g_vm) return NULL;
    DxValue args[1] = { {.tag = DX_VAL_OBJ, .obj = dobj} };
    DxValue result = {0};
    g_vm->insn_count = 0;
    dx_vm_execute_method(g_vm, m, args, 1, &result);
    if (result.tag == DX_VAL_OBJ) return dx_jni_wrap_object(result.obj);
    return NULL;
}

static jobject JNICALL jni_CallObjectMethodV(JNIEnv *env, jobject obj, jmethodID methodID, va_list args) {
    (void)args;
    return jni_CallObjectMethod(env, obj, methodID);
}

static jobject JNICALL jni_CallObjectMethodA(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) {
    (void)args;
    return jni_CallObjectMethod(env, obj, methodID);
}

// Helper: dispatch a JNI Call*Method and return the DxValue result
static DxValue jni_dispatch_method(jobject obj, jmethodID mid) {
    DxValue result = {0};
    DxMethod *m = (DxMethod *)mid;
    DxObject *dobj = dx_jni_unwrap_object(obj);
    if (!m || !g_vm) return result;
    DxValue args[1] = { {.tag = DX_VAL_OBJ, .obj = dobj} };
    g_vm->insn_count = 0;
    dx_vm_execute_method(g_vm, m, args, 1, &result);
    return result;
}

// Boolean
static jboolean JNICALL jni_CallBooleanMethod(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    (void)env;
    DxValue r = jni_dispatch_method(obj, mid);
    return (r.tag == DX_VAL_INT) ? (jboolean)(r.i != 0) : JNI_FALSE;
}
static jboolean JNICALL jni_CallBooleanMethodV(JNIEnv *env, jobject obj, jmethodID mid, va_list a) {
    (void)env; (void)a;
    DxValue r = jni_dispatch_method(obj, mid);
    return (r.tag == DX_VAL_INT) ? (jboolean)(r.i != 0) : JNI_FALSE;
}
static jboolean JNICALL jni_CallBooleanMethodA(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *a) {
    (void)env; (void)a;
    DxValue r = jni_dispatch_method(obj, mid);
    return (r.tag == DX_VAL_INT) ? (jboolean)(r.i != 0) : JNI_FALSE;
}

// Byte
static jbyte JNICALL jni_CallByteMethod(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    (void)env; (void)obj; (void)mid; return 0;
}
static jbyte JNICALL jni_CallByteMethodV(JNIEnv *env, jobject obj, jmethodID mid, va_list a) {
    (void)env; (void)obj; (void)mid; (void)a; return 0;
}
static jbyte JNICALL jni_CallByteMethodA(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *a) {
    (void)env; (void)obj; (void)mid; (void)a; return 0;
}

// Char
static jchar JNICALL jni_CallCharMethod(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    (void)env; (void)obj; (void)mid; return 0;
}
static jchar JNICALL jni_CallCharMethodV(JNIEnv *env, jobject obj, jmethodID mid, va_list a) {
    (void)env; (void)obj; (void)mid; (void)a; return 0;
}
static jchar JNICALL jni_CallCharMethodA(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *a) {
    (void)env; (void)obj; (void)mid; (void)a; return 0;
}

// Short
static jshort JNICALL jni_CallShortMethod(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    (void)env; (void)obj; (void)mid; return 0;
}
static jshort JNICALL jni_CallShortMethodV(JNIEnv *env, jobject obj, jmethodID mid, va_list a) {
    (void)env; (void)obj; (void)mid; (void)a; return 0;
}
static jshort JNICALL jni_CallShortMethodA(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *a) {
    (void)env; (void)obj; (void)mid; (void)a; return 0;
}

// Int
static jint JNICALL jni_CallIntMethod(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    (void)env;
    DxValue r = jni_dispatch_method(obj, mid);
    return (r.tag == DX_VAL_INT) ? (jint)r.i : 0;
}
static jint JNICALL jni_CallIntMethodV(JNIEnv *env, jobject obj, jmethodID mid, va_list a) {
    (void)env; (void)a;
    DxValue r = jni_dispatch_method(obj, mid);
    return (r.tag == DX_VAL_INT) ? (jint)r.i : 0;
}
static jint JNICALL jni_CallIntMethodA(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *a) {
    (void)env; (void)a;
    DxValue r = jni_dispatch_method(obj, mid);
    return (r.tag == DX_VAL_INT) ? (jint)r.i : 0;
}

// Long
static jlong JNICALL jni_CallLongMethod(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    (void)env;
    DxValue r = jni_dispatch_method(obj, mid);
    return (r.tag == DX_VAL_LONG) ? (jlong)r.l : 0;
}
static jlong JNICALL jni_CallLongMethodV(JNIEnv *env, jobject obj, jmethodID mid, va_list a) {
    (void)env; (void)a;
    DxValue r = jni_dispatch_method(obj, mid);
    return (r.tag == DX_VAL_LONG) ? (jlong)r.l : 0;
}
static jlong JNICALL jni_CallLongMethodA(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *a) {
    (void)env; (void)a;
    DxValue r = jni_dispatch_method(obj, mid);
    return (r.tag == DX_VAL_LONG) ? (jlong)r.l : 0;
}

// Float
static jfloat JNICALL jni_CallFloatMethod(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    (void)env; (void)obj; (void)mid; return 0.0f;
}
static jfloat JNICALL jni_CallFloatMethodV(JNIEnv *env, jobject obj, jmethodID mid, va_list a) {
    (void)env; (void)obj; (void)mid; (void)a; return 0.0f;
}
static jfloat JNICALL jni_CallFloatMethodA(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *a) {
    (void)env; (void)obj; (void)mid; (void)a; return 0.0f;
}

// Double
static jdouble JNICALL jni_CallDoubleMethod(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    (void)env; (void)obj; (void)mid; return 0.0;
}
static jdouble JNICALL jni_CallDoubleMethodV(JNIEnv *env, jobject obj, jmethodID mid, va_list a) {
    (void)env; (void)obj; (void)mid; (void)a; return 0.0;
}
static jdouble JNICALL jni_CallDoubleMethodA(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *a) {
    (void)env; (void)obj; (void)mid; (void)a; return 0.0;
}

// Void
static void JNICALL jni_CallVoidMethod(JNIEnv *env, jobject obj, jmethodID methodID, ...) {
    (void)env;
    DxMethod *m = (DxMethod *)methodID;
    DxObject *dobj = dx_jni_unwrap_object(obj);
    if (!m || !g_vm) return;
    DxValue args[1] = { {.tag = DX_VAL_OBJ, .obj = dobj} };
    g_vm->insn_count = 0;
    dx_vm_execute_method(g_vm, m, args, 1, NULL);
}
static void JNICALL jni_CallVoidMethodV(JNIEnv *env, jobject obj, jmethodID mid, va_list a) {
    (void)a;
    jni_CallVoidMethod(env, obj, mid);
}
static void JNICALL jni_CallVoidMethodA(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *a) {
    (void)a;
    jni_CallVoidMethod(env, obj, mid);
}

// CallNonvirtual — all return defaults
#define JNI_NONVIRTUAL_STUB(Type, type, default_val) \
static type JNICALL jni_CallNonvirtual##Type##Method(JNIEnv *env, jobject obj, jclass c, jmethodID m, ...) { \
    (void)env; (void)obj; (void)c; (void)m; return default_val; } \
static type JNICALL jni_CallNonvirtual##Type##MethodV(JNIEnv *env, jobject obj, jclass c, jmethodID m, va_list a) { \
    (void)env; (void)obj; (void)c; (void)m; (void)a; return default_val; } \
static type JNICALL jni_CallNonvirtual##Type##MethodA(JNIEnv *env, jobject obj, jclass c, jmethodID m, const jvalue *a) { \
    (void)env; (void)obj; (void)c; (void)m; (void)a; return default_val; }

JNI_NONVIRTUAL_STUB(Object, jobject, NULL)
JNI_NONVIRTUAL_STUB(Boolean, jboolean, JNI_FALSE)
JNI_NONVIRTUAL_STUB(Byte, jbyte, 0)
JNI_NONVIRTUAL_STUB(Char, jchar, 0)
JNI_NONVIRTUAL_STUB(Short, jshort, 0)
JNI_NONVIRTUAL_STUB(Int, jint, 0)
JNI_NONVIRTUAL_STUB(Long, jlong, 0)
JNI_NONVIRTUAL_STUB(Float, jfloat, 0.0f)
JNI_NONVIRTUAL_STUB(Double, jdouble, 0.0)

static void JNICALL jni_CallNonvirtualVoidMethod(JNIEnv *env, jobject obj, jclass c, jmethodID m, ...) {
    (void)env; (void)obj; (void)c; (void)m;
}
static void JNICALL jni_CallNonvirtualVoidMethodV(JNIEnv *env, jobject obj, jclass c, jmethodID m, va_list a) {
    (void)env; (void)obj; (void)c; (void)m; (void)a;
}
static void JNICALL jni_CallNonvirtualVoidMethodA(JNIEnv *env, jobject obj, jclass c, jmethodID m, const jvalue *a) {
    (void)env; (void)obj; (void)c; (void)m; (void)a;
}

// Field access — return defaults, set is no-op
static jfieldID JNICALL jni_GetFieldID(JNIEnv *env, jclass clazz, const char *name, const char *sig) {
    (void)env; (void)sig;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    if (!cls || !name) return NULL;
    // Encode field name as the fieldID (we'll look it up by name)
    return (jfieldID)dx_strdup(name);
}

static jobject JNICALL jni_GetObjectField(JNIEnv *env, jobject obj, jfieldID fieldID) {
    (void)env;
    DxObject *dobj = dx_jni_unwrap_object(obj);
    const char *name = (const char *)fieldID;
    if (!dobj || !name) return NULL;
    DxValue val = {0};
    dx_vm_get_field(dobj, name, &val);
    return (val.tag == DX_VAL_OBJ) ? dx_jni_wrap_object(val.obj) : NULL;
}

// Primitive field getters — look up by name, extract appropriate value
#define JNI_GET_FIELD_IMPL(Type, type, tag_check, member, default_val) \
static type JNICALL jni_Get##Type##Field(JNIEnv *env, jobject obj, jfieldID fid) { \
    (void)env; \
    DxObject *dobj = dx_jni_unwrap_object(obj); \
    const char *name = (const char *)fid; \
    if (!dobj || !name) return default_val; \
    DxValue val = {0}; \
    dx_vm_get_field(dobj, name, &val); \
    return (val.tag == tag_check) ? (type)val.member : default_val; }

JNI_GET_FIELD_IMPL(Boolean, jboolean, DX_VAL_INT, i, JNI_FALSE)
JNI_GET_FIELD_IMPL(Byte, jbyte, DX_VAL_INT, i, 0)
JNI_GET_FIELD_IMPL(Char, jchar, DX_VAL_INT, i, 0)
JNI_GET_FIELD_IMPL(Short, jshort, DX_VAL_INT, i, 0)
JNI_GET_FIELD_IMPL(Int, jint, DX_VAL_INT, i, 0)
JNI_GET_FIELD_IMPL(Long, jlong, DX_VAL_LONG, l, 0)
JNI_GET_FIELD_IMPL(Float, jfloat, DX_VAL_FLOAT, f, 0.0f)
JNI_GET_FIELD_IMPL(Double, jdouble, DX_VAL_DOUBLE, d, 0.0)

static void JNICALL jni_SetObjectField(JNIEnv *env, jobject obj, jfieldID fieldID, jobject val) {
    (void)env;
    DxObject *dobj = dx_jni_unwrap_object(obj);
    const char *name = (const char *)fieldID;
    if (!dobj || !name) return;
    DxValue v = {.tag = DX_VAL_OBJ, .obj = dx_jni_unwrap_object(val)};
    dx_vm_set_field(dobj, name, v);
}

// Primitive field setters — look up by name, set appropriate value
static void JNICALL jni_SetBooleanField(JNIEnv *env, jobject obj, jfieldID fid, jboolean val) {
    (void)env; DxObject *d = dx_jni_unwrap_object(obj); const char *n = (const char *)fid;
    if (d && n) { DxValue v = {.tag = DX_VAL_INT, .i = val ? 1 : 0}; dx_vm_set_field(d, n, v); }
}
static void JNICALL jni_SetByteField(JNIEnv *env, jobject obj, jfieldID fid, jbyte val) {
    (void)env; DxObject *d = dx_jni_unwrap_object(obj); const char *n = (const char *)fid;
    if (d && n) { DxValue v = {.tag = DX_VAL_INT, .i = val}; dx_vm_set_field(d, n, v); }
}
static void JNICALL jni_SetCharField(JNIEnv *env, jobject obj, jfieldID fid, jchar val) {
    (void)env; DxObject *d = dx_jni_unwrap_object(obj); const char *n = (const char *)fid;
    if (d && n) { DxValue v = {.tag = DX_VAL_INT, .i = val}; dx_vm_set_field(d, n, v); }
}
static void JNICALL jni_SetShortField(JNIEnv *env, jobject obj, jfieldID fid, jshort val) {
    (void)env; DxObject *d = dx_jni_unwrap_object(obj); const char *n = (const char *)fid;
    if (d && n) { DxValue v = {.tag = DX_VAL_INT, .i = val}; dx_vm_set_field(d, n, v); }
}
static void JNICALL jni_SetIntField(JNIEnv *env, jobject obj, jfieldID fid, jint val) {
    (void)env; DxObject *d = dx_jni_unwrap_object(obj); const char *n = (const char *)fid;
    if (d && n) { DxValue v = {.tag = DX_VAL_INT, .i = val}; dx_vm_set_field(d, n, v); }
}
static void JNICALL jni_SetLongField(JNIEnv *env, jobject obj, jfieldID fid, jlong val) {
    (void)env; DxObject *d = dx_jni_unwrap_object(obj); const char *n = (const char *)fid;
    if (d && n) { DxValue v = {.tag = DX_VAL_LONG, .l = val}; dx_vm_set_field(d, n, v); }
}
static void JNICALL jni_SetFloatField(JNIEnv *env, jobject obj, jfieldID fid, jfloat val) {
    (void)env; DxObject *d = dx_jni_unwrap_object(obj); const char *n = (const char *)fid;
    if (d && n) { DxValue v = {.tag = DX_VAL_FLOAT, .f = val}; dx_vm_set_field(d, n, v); }
}
static void JNICALL jni_SetDoubleField(JNIEnv *env, jobject obj, jfieldID fid, jdouble val) {
    (void)env; DxObject *d = dx_jni_unwrap_object(obj); const char *n = (const char *)fid;
    if (d && n) { DxValue v = {.tag = DX_VAL_DOUBLE, .d = val}; dx_vm_set_field(d, n, v); }
}

// Static method calls
static jmethodID JNICALL jni_GetStaticMethodID(JNIEnv *env, jclass clazz,
                                                const char *name, const char *sig) {
    (void)env; (void)sig;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    if (!cls || !name) return NULL;
    DxMethod *m = dx_vm_find_method(cls, name, NULL);
    return (jmethodID)m;
}

// CallStatic<Type>Method — return defaults
#define JNI_CALL_STATIC_STUB(Type, type, default_val) \
static type JNICALL jni_CallStatic##Type##Method(JNIEnv *env, jclass c, jmethodID m, ...) { \
    (void)env; (void)c; (void)m; return default_val; } \
static type JNICALL jni_CallStatic##Type##MethodV(JNIEnv *env, jclass c, jmethodID m, va_list a) { \
    (void)env; (void)c; (void)m; (void)a; return default_val; } \
static type JNICALL jni_CallStatic##Type##MethodA(JNIEnv *env, jclass c, jmethodID m, const jvalue *a) { \
    (void)env; (void)c; (void)m; (void)a; return default_val; }

JNI_CALL_STATIC_STUB(Object, jobject, NULL)
JNI_CALL_STATIC_STUB(Boolean, jboolean, JNI_FALSE)
JNI_CALL_STATIC_STUB(Byte, jbyte, 0)
JNI_CALL_STATIC_STUB(Char, jchar, 0)
JNI_CALL_STATIC_STUB(Short, jshort, 0)
JNI_CALL_STATIC_STUB(Int, jint, 0)
JNI_CALL_STATIC_STUB(Long, jlong, 0)
JNI_CALL_STATIC_STUB(Float, jfloat, 0.0f)
JNI_CALL_STATIC_STUB(Double, jdouble, 0.0)

static void JNICALL jni_CallStaticVoidMethod(JNIEnv *env, jclass c, jmethodID m, ...) {
    (void)env; (void)c; (void)m;
}
static void JNICALL jni_CallStaticVoidMethodV(JNIEnv *env, jclass c, jmethodID m, va_list a) {
    (void)env; (void)c; (void)m; (void)a;
}
static void JNICALL jni_CallStaticVoidMethodA(JNIEnv *env, jclass c, jmethodID m, const jvalue *a) {
    (void)env; (void)c; (void)m; (void)a;
}

// Static field access
static jfieldID JNICALL jni_GetStaticFieldID(JNIEnv *env, jclass clazz,
                                              const char *name, const char *sig) {
    (void)env; (void)sig;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    if (!cls || !name) return NULL;
    // Verify the field actually exists and is static
    for (uint32_t i = 0; i < cls->static_field_count; i++) {
        if (cls->field_defs[i].flags & DX_ACC_STATIC) {
            if (strcmp(cls->field_defs[i].name, name) == 0) {
                return (jfieldID)cls->field_defs[i].name;
            }
        }
    }
    return NULL;
}

#define JNI_GET_STATIC_FIELD_STUB(Type, type, default_val) \
static type JNICALL jni_GetStatic##Type##Field(JNIEnv *env, jclass c, jfieldID fid) { \
    (void)env; (void)c; (void)fid; return default_val; }

static jobject JNICALL jni_GetStaticObjectField(JNIEnv *env, jclass clazz, jfieldID fieldID) {
    (void)env;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    const char *name = (const char *)fieldID;
    if (!cls || !name) return NULL;
    for (uint32_t i = 0; i < cls->static_field_count; i++) {
        if ((cls->field_defs[i].flags & DX_ACC_STATIC) &&
            strcmp(cls->field_defs[i].name, name) == 0) {
            DxValue val = cls->static_fields[i];
            if (val.tag == DX_VAL_OBJ) {
                return dx_jni_wrap_object(val.obj);
            }
            return NULL;
        }
    }
    return NULL;
}
JNI_GET_STATIC_FIELD_STUB(Boolean, jboolean, JNI_FALSE)
JNI_GET_STATIC_FIELD_STUB(Byte, jbyte, 0)
JNI_GET_STATIC_FIELD_STUB(Char, jchar, 0)
JNI_GET_STATIC_FIELD_STUB(Short, jshort, 0)
JNI_GET_STATIC_FIELD_STUB(Int, jint, 0)
JNI_GET_STATIC_FIELD_STUB(Long, jlong, 0)
JNI_GET_STATIC_FIELD_STUB(Float, jfloat, 0.0f)
JNI_GET_STATIC_FIELD_STUB(Double, jdouble, 0.0)

#define JNI_SET_STATIC_FIELD_STUB(Type, type) \
static void JNICALL jni_SetStatic##Type##Field(JNIEnv *env, jclass c, jfieldID fid, type val) { \
    (void)env; (void)c; (void)fid; (void)val; }

static void JNICALL jni_SetStaticObjectField(JNIEnv *env, jclass clazz, jfieldID fieldID, jobject val) {
    (void)env;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    const char *name = (const char *)fieldID;
    if (!cls || !name) return;
    for (uint32_t i = 0; i < cls->static_field_count; i++) {
        if ((cls->field_defs[i].flags & DX_ACC_STATIC) &&
            strcmp(cls->field_defs[i].name, name) == 0) {
            cls->static_fields[i] = DX_OBJ_VALUE(dx_jni_unwrap_object(val));
            return;
        }
    }
}
JNI_SET_STATIC_FIELD_STUB(Boolean, jboolean)
JNI_SET_STATIC_FIELD_STUB(Byte, jbyte)
JNI_SET_STATIC_FIELD_STUB(Char, jchar)
JNI_SET_STATIC_FIELD_STUB(Short, jshort)
JNI_SET_STATIC_FIELD_STUB(Int, jint)
JNI_SET_STATIC_FIELD_STUB(Long, jlong)
JNI_SET_STATIC_FIELD_STUB(Float, jfloat)
JNI_SET_STATIC_FIELD_STUB(Double, jdouble)

// ============================================================================
// String operations — these are the most commonly used JNI functions
// ============================================================================

static jstring JNICALL jni_NewString(JNIEnv *env, const jchar *unicode, jsize len) {
    (void)env;
    if (!g_vm || !unicode) return NULL;
    // Convert UTF-16 to UTF-8 (simple ASCII subset)
    char *buf = (char *)dx_malloc((size_t)len + 1);
    if (!buf) return NULL;
    for (jsize i = 0; i < len; i++) {
        buf[i] = (char)(unicode[i] & 0x7F);
    }
    buf[len] = '\0';
    DxObject *str = dx_vm_create_string(g_vm, buf);
    dx_free(buf);
    return dx_jni_wrap_object(str);
}

// Helper: convert UTF-8 string to UTF-16 (jchar) buffer.
// Returns allocated buffer and sets *out_len to the number of UTF-16 code units.
// Handles ASCII correctly; multi-byte UTF-8 sequences are decoded properly.
// Surrogate pairs are emitted for codepoints above U+FFFF.
static jchar *utf8_to_utf16(const char *utf8, jsize *out_len) {
    if (!utf8) { if (out_len) *out_len = 0; return NULL; }
    const unsigned char *s = (const unsigned char *)utf8;
    // First pass: count UTF-16 code units needed
    jsize count = 0;
    for (size_t i = 0; s[i]; ) {
        unsigned char c = s[i];
        uint32_t cp;
        if (c < 0x80) {
            cp = c; i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            cp = c & 0x1F;
            if (s[i+1]) { cp = (cp << 6) | (s[i+1] & 0x3F); i += 2; }
            else { cp = c; i += 1; }
        } else if ((c & 0xF0) == 0xE0) {
            cp = c & 0x0F;
            if (s[i+1] && s[i+2]) {
                cp = (cp << 6) | (s[i+1] & 0x3F);
                cp = (cp << 6) | (s[i+2] & 0x3F);
                i += 3;
            } else { cp = c; i += 1; }
        } else if ((c & 0xF8) == 0xF0) {
            cp = c & 0x07;
            if (s[i+1] && s[i+2] && s[i+3]) {
                cp = (cp << 6) | (s[i+1] & 0x3F);
                cp = (cp << 6) | (s[i+2] & 0x3F);
                cp = (cp << 6) | (s[i+3] & 0x3F);
                i += 4;
            } else { cp = c; i += 1; }
        } else {
            cp = c; i += 1;
        }
        count += (cp > 0xFFFF) ? 2 : 1;
    }
    // Allocate buffer
    jchar *buf = (jchar *)dx_malloc((size_t)(count + 1) * sizeof(jchar));
    if (!buf) { if (out_len) *out_len = 0; return NULL; }
    // Second pass: fill buffer
    jsize idx = 0;
    for (size_t i = 0; s[i]; ) {
        unsigned char c = s[i];
        uint32_t cp;
        if (c < 0x80) {
            cp = c; i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            cp = c & 0x1F;
            if (s[i+1]) { cp = (cp << 6) | (s[i+1] & 0x3F); i += 2; }
            else { cp = c; i += 1; }
        } else if ((c & 0xF0) == 0xE0) {
            cp = c & 0x0F;
            if (s[i+1] && s[i+2]) {
                cp = (cp << 6) | (s[i+1] & 0x3F);
                cp = (cp << 6) | (s[i+2] & 0x3F);
                i += 3;
            } else { cp = c; i += 1; }
        } else if ((c & 0xF8) == 0xF0) {
            cp = c & 0x07;
            if (s[i+1] && s[i+2] && s[i+3]) {
                cp = (cp << 6) | (s[i+1] & 0x3F);
                cp = (cp << 6) | (s[i+2] & 0x3F);
                cp = (cp << 6) | (s[i+3] & 0x3F);
                i += 4;
            } else { cp = c; i += 1; }
        } else {
            cp = c; i += 1;
        }
        if (cp > 0xFFFF) {
            // Encode as surrogate pair
            cp -= 0x10000;
            buf[idx++] = (jchar)(0xD800 | (cp >> 10));
            buf[idx++] = (jchar)(0xDC00 | (cp & 0x3FF));
        } else {
            buf[idx++] = (jchar)cp;
        }
    }
    buf[idx] = 0;
    if (out_len) *out_len = count;
    return buf;
}

static jsize JNICALL jni_GetStringLength(JNIEnv *env, jstring str) {
    (void)env;
    DxObject *sobj = dx_jni_unwrap_object(str);
    const char *val = dx_vm_get_string_value(sobj);
    if (!val) return 0;
    jsize len = 0;
    jchar *tmp = utf8_to_utf16(val, &len);
    if (tmp) dx_free(tmp);
    return len;
}

static const jchar *JNICALL jni_GetStringChars(JNIEnv *env, jstring str, jboolean *isCopy) {
    (void)env;
    DxObject *sobj = dx_jni_unwrap_object(str);
    const char *val = dx_vm_get_string_value(sobj);
    if (!val) {
        if (isCopy) *isCopy = JNI_FALSE;
        return NULL;
    }
    jsize len = 0;
    jchar *buf = utf8_to_utf16(val, &len);
    if (isCopy) *isCopy = (jboolean)(buf ? JNI_TRUE : JNI_FALSE);
    return buf;
}

static void JNICALL jni_ReleaseStringChars(JNIEnv *env, jstring str, const jchar *chars) {
    (void)env; (void)str;
    if (chars) dx_free((void *)chars);
}

static jstring JNICALL jni_NewStringUTF(JNIEnv *env, const char *utf) {
    (void)env;
    if (!g_vm || !utf) return NULL;
    DxObject *str = dx_vm_create_string(g_vm, utf);
    return dx_jni_wrap_object(str);
}

static jsize JNICALL jni_GetStringUTFLength(JNIEnv *env, jstring str) {
    (void)env;
    DxObject *sobj = dx_jni_unwrap_object(str);
    const char *val = dx_vm_get_string_value(sobj);
    return val ? (jsize)strlen(val) : 0;
}

static const char *JNICALL jni_GetStringUTFChars(JNIEnv *env, jstring str, jboolean *isCopy) {
    (void)env;
    if (isCopy) *isCopy = JNI_FALSE;
    DxObject *sobj = dx_jni_unwrap_object(str);
    return dx_vm_get_string_value(sobj);
}

static void JNICALL jni_ReleaseStringUTFChars(JNIEnv *env, jstring str, const char *chars) {
    (void)env; (void)str; (void)chars;
    // We don't copy, so nothing to release
}

// ============================================================================
// Array operations
// ============================================================================

static jsize JNICALL jni_GetArrayLength(JNIEnv *env, jarray array) {
    (void)env;
    DxObject *arr = dx_jni_unwrap_object(array);
    if (!arr || !arr->is_array) return 0;
    return (jsize)arr->array_length;
}

static jobjectArray JNICALL jni_NewObjectArray(JNIEnv *env, jsize len, jclass clazz, jobject init) {
    (void)env; (void)clazz; (void)init;
    if (!g_vm) return NULL;
    DxObject *arr = dx_vm_alloc_array(g_vm, (uint32_t)len);
    return (jobjectArray)dx_jni_wrap_object(arr);
}

static jobject JNICALL jni_GetObjectArrayElement(JNIEnv *env, jobjectArray array, jsize index) {
    (void)env;
    DxObject *arr = dx_jni_unwrap_object(array);
    if (!arr || !arr->is_array || index < 0 || (uint32_t)index >= arr->array_length) return NULL;
    DxValue v = arr->array_elements[index];
    return (v.tag == DX_VAL_OBJ) ? dx_jni_wrap_object(v.obj) : NULL;
}

static void JNICALL jni_SetObjectArrayElement(JNIEnv *env, jobjectArray array, jsize index, jobject val) {
    (void)env;
    DxObject *arr = dx_jni_unwrap_object(array);
    if (!arr || !arr->is_array || index < 0 || (uint32_t)index >= arr->array_length) return;
    arr->array_elements[index] = (DxValue){.tag = DX_VAL_OBJ, .obj = dx_jni_unwrap_object(val)};
}

#define JNI_NEW_ARRAY_STUB(Type, type) \
static type##Array JNICALL jni_New##Type##Array(JNIEnv *env, jsize len) { \
    (void)env; \
    if (!g_vm) return NULL; \
    DxObject *arr = dx_vm_alloc_array(g_vm, (uint32_t)len); \
    return (type##Array)dx_jni_wrap_object(arr); \
}

JNI_NEW_ARRAY_STUB(Boolean, jboolean)
JNI_NEW_ARRAY_STUB(Byte, jbyte)
JNI_NEW_ARRAY_STUB(Char, jchar)
JNI_NEW_ARRAY_STUB(Short, jshort)
JNI_NEW_ARRAY_STUB(Int, jint)
JNI_NEW_ARRAY_STUB(Long, jlong)
JNI_NEW_ARRAY_STUB(Float, jfloat)
JNI_NEW_ARRAY_STUB(Double, jdouble)

// Get<Type>ArrayElements — return NULL (no direct buffer access)
#define JNI_GET_ARRAY_ELEMENTS_STUB(Type, type) \
static type *JNICALL jni_Get##Type##ArrayElements(JNIEnv *env, type##Array arr, jboolean *isCopy) { \
    (void)env; (void)arr; if (isCopy) *isCopy = JNI_FALSE; return NULL; }

JNI_GET_ARRAY_ELEMENTS_STUB(Boolean, jboolean)
JNI_GET_ARRAY_ELEMENTS_STUB(Byte, jbyte)
JNI_GET_ARRAY_ELEMENTS_STUB(Char, jchar)
JNI_GET_ARRAY_ELEMENTS_STUB(Short, jshort)
JNI_GET_ARRAY_ELEMENTS_STUB(Int, jint)
JNI_GET_ARRAY_ELEMENTS_STUB(Long, jlong)
JNI_GET_ARRAY_ELEMENTS_STUB(Float, jfloat)
JNI_GET_ARRAY_ELEMENTS_STUB(Double, jdouble)

// Release<Type>ArrayElements — no-ops
#define JNI_RELEASE_ARRAY_ELEMENTS_STUB(Type, type) \
static void JNICALL jni_Release##Type##ArrayElements(JNIEnv *env, type##Array arr, type *elems, jint mode) { \
    (void)env; (void)arr; (void)elems; (void)mode; }

JNI_RELEASE_ARRAY_ELEMENTS_STUB(Boolean, jboolean)
JNI_RELEASE_ARRAY_ELEMENTS_STUB(Byte, jbyte)
JNI_RELEASE_ARRAY_ELEMENTS_STUB(Char, jchar)
JNI_RELEASE_ARRAY_ELEMENTS_STUB(Short, jshort)
JNI_RELEASE_ARRAY_ELEMENTS_STUB(Int, jint)
JNI_RELEASE_ARRAY_ELEMENTS_STUB(Long, jlong)
JNI_RELEASE_ARRAY_ELEMENTS_STUB(Float, jfloat)
JNI_RELEASE_ARRAY_ELEMENTS_STUB(Double, jdouble)

// Get/Set<Type>ArrayRegion — no-ops
#define JNI_ARRAY_REGION_STUBS(Type, type) \
static void JNICALL jni_Get##Type##ArrayRegion(JNIEnv *env, type##Array arr, jsize start, jsize len, type *buf) { \
    (void)env; (void)arr; (void)start; (void)len; (void)buf; } \
static void JNICALL jni_Set##Type##ArrayRegion(JNIEnv *env, type##Array arr, jsize start, jsize len, const type *buf) { \
    (void)env; (void)arr; (void)start; (void)len; (void)buf; }

JNI_ARRAY_REGION_STUBS(Boolean, jboolean)
JNI_ARRAY_REGION_STUBS(Byte, jbyte)
JNI_ARRAY_REGION_STUBS(Char, jchar)
JNI_ARRAY_REGION_STUBS(Short, jshort)
JNI_ARRAY_REGION_STUBS(Int, jint)
JNI_ARRAY_REGION_STUBS(Long, jlong)
JNI_ARRAY_REGION_STUBS(Float, jfloat)
JNI_ARRAY_REGION_STUBS(Double, jdouble)

// RegisterNatives / UnregisterNatives
static jint JNICALL jni_RegisterNatives(JNIEnv *env, jclass clazz,
                                         const JNINativeMethod *methods, jint nMethods) {
    (void)env;
    DxClass *cls = dx_jni_unwrap_class(clazz);
    if (!cls) {
        DX_WARN(TAG, "RegisterNatives: null class");
        return -1;
    }
    DX_INFO(TAG, "RegisterNatives: %s (%d methods)", cls->descriptor, nMethods);

    for (jint i = 0; i < nMethods; i++) {
        const char *name = methods[i].name;
        if (!name) continue;

        // Find method by name (pass NULL shorty to match by name only)
        DxMethod *method = dx_vm_find_method(cls, name, NULL);
        if (!method) {
            DX_WARN(TAG, "  RegisterNatives: method %s.%s not found",
                    cls->descriptor, name);
            continue;
        }

        method->native_fn = (DxNativeMethodFn)methods[i].fnPtr;
        method->is_native = true;
        DX_INFO(TAG, "  Bound native: %s.%s -> %p",
                cls->descriptor, name, methods[i].fnPtr);
    }

    return 0;
}

static jint JNICALL jni_UnregisterNatives(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
    return 0;
}

static jint JNICALL jni_MonitorEnter(JNIEnv *env, jobject obj) {
    (void)env; (void)obj;
    return 0;
}

static jint JNICALL jni_MonitorExit(JNIEnv *env, jobject obj) {
    (void)env; (void)obj;
    return 0;
}

static jint JNICALL jni_GetJavaVM(JNIEnv *env, JavaVM **vm) {
    (void)env;
    if (vm) *vm = NULL; // We don't have a JavaVM struct yet
    return 0;
}

static void JNICALL jni_GetStringRegion(JNIEnv *env, jstring str, jsize start, jsize len, jchar *buf) {
    (void)env;
    if (!buf) return;
    DxObject *sobj = dx_jni_unwrap_object(str);
    const char *val = dx_vm_get_string_value(sobj);
    if (!val) return;
    jsize total = 0;
    jchar *utf16 = utf8_to_utf16(val, &total);
    if (!utf16) return;
    if (start < 0 || start >= total || len <= 0) { dx_free(utf16); return; }
    jsize copy_len = len;
    if (start + copy_len > total) copy_len = total - start;
    memcpy(buf, utf16 + start, (size_t)copy_len * sizeof(jchar));
    dx_free(utf16);
}

static void JNICALL jni_GetStringUTFRegion(JNIEnv *env, jstring str, jsize start, jsize len, char *buf) {
    (void)env;
    DxObject *sobj = dx_jni_unwrap_object(str);
    const char *val = dx_vm_get_string_value(sobj);
    if (!val || !buf) return;
    size_t slen = strlen(val);
    if ((size_t)start >= slen) return;
    size_t copy_len = (size_t)len;
    if ((size_t)start + copy_len > slen) copy_len = slen - (size_t)start;
    memcpy(buf, val + start, copy_len);
    buf[copy_len] = '\0';
}

static void *JNICALL jni_GetPrimitiveArrayCritical(JNIEnv *env, jarray array, jboolean *isCopy) {
    (void)env; (void)array;
    if (isCopy) *isCopy = JNI_FALSE;
    return NULL;
}

static void JNICALL jni_ReleasePrimitiveArrayCritical(JNIEnv *env, jarray array, void *carray, jint mode) {
    (void)env; (void)array; (void)carray; (void)mode;
}

static const jchar *JNICALL jni_GetStringCritical(JNIEnv *env, jstring string, jboolean *isCopy) {
    (void)env; (void)string;
    if (isCopy) *isCopy = JNI_FALSE;
    return NULL;
}

static void JNICALL jni_ReleaseStringCritical(JNIEnv *env, jstring string, const jchar *cstring) {
    (void)env; (void)string; (void)cstring;
}

static jweak JNICALL jni_NewWeakGlobalRef(JNIEnv *env, jobject obj) {
    (void)env;
    return obj;
}

static void JNICALL jni_DeleteWeakGlobalRef(JNIEnv *env, jweak ref) {
    (void)env; (void)ref;
}

static jboolean JNICALL jni_ExceptionCheck(JNIEnv *env) {
    (void)env;
    return (g_vm && g_vm->pending_exception) ? JNI_TRUE : JNI_FALSE;
}

static jobject JNICALL jni_NewDirectByteBuffer(JNIEnv *env, void *address, jlong capacity) {
    (void)env; (void)address; (void)capacity;
    return NULL;
}

static void *JNICALL jni_GetDirectBufferAddress(JNIEnv *env, jobject buf) {
    (void)env; (void)buf;
    return NULL;
}

static jlong JNICALL jni_GetDirectBufferCapacity(JNIEnv *env, jobject buf) {
    (void)env; (void)buf;
    return -1;
}

static jobjectRefType JNICALL jni_GetObjectRefType(JNIEnv *env, jobject obj) {
    (void)env; (void)obj;
    return JNILocalRefType;
}

// ============================================================================
// The complete JNINativeInterface_ function table
// ============================================================================

static struct JNINativeInterface_ g_jni_functions = {
    // reserved 0-3
    NULL, NULL, NULL, NULL,

    // 4: GetVersion
    jni_GetVersion,

    // 5: DefineClass
    jni_DefineClass,
    // 6: FindClass
    jni_FindClass,

    // 7: FromReflectedMethod
    jni_FromReflectedMethod,
    // 8: FromReflectedField
    jni_FromReflectedField,

    // 9: ToReflectedMethod
    jni_ToReflectedMethod,

    // 10: GetSuperclass
    jni_GetSuperclass,
    // 11: IsAssignableFrom
    jni_IsAssignableFrom,

    // 12: ToReflectedField
    jni_ToReflectedField,

    // 13: Throw
    jni_Throw,
    // 14: ThrowNew
    jni_ThrowNew,
    // 15: ExceptionOccurred
    jni_ExceptionOccurred,
    // 16: ExceptionDescribe
    jni_ExceptionDescribe,
    // 17: ExceptionClear
    jni_ExceptionClear,
    // 18: FatalError
    jni_FatalError,

    // 19: PushLocalFrame
    jni_PushLocalFrame,
    // 20: PopLocalFrame
    jni_PopLocalFrame,

    // 21: NewGlobalRef
    jni_NewGlobalRef,
    // 22: DeleteGlobalRef
    jni_DeleteGlobalRef,
    // 23: DeleteLocalRef
    jni_DeleteLocalRef,
    // 24: IsSameObject
    jni_IsSameObject,
    // 25: NewLocalRef
    jni_NewLocalRef,
    // 26: EnsureLocalCapacity
    jni_EnsureLocalCapacity,

    // 27: AllocObject
    jni_AllocObject,
    // 28: NewObject
    jni_NewObject,
    // 29: NewObjectV
    jni_NewObjectV,
    // 30: NewObjectA
    jni_NewObjectA,

    // 31: GetObjectClass
    jni_GetObjectClass,
    // 32: IsInstanceOf
    jni_IsInstanceOf,

    // 33: GetMethodID
    jni_GetMethodID,

    // 34-36: CallObjectMethod{,V,A}
    jni_CallObjectMethod,
    jni_CallObjectMethodV,
    jni_CallObjectMethodA,

    // 37-39: CallBooleanMethod{,V,A}
    jni_CallBooleanMethod,
    jni_CallBooleanMethodV,
    jni_CallBooleanMethodA,

    // 40-42: CallByteMethod{,V,A}
    jni_CallByteMethod,
    jni_CallByteMethodV,
    jni_CallByteMethodA,

    // 43-45: CallCharMethod{,V,A}
    jni_CallCharMethod,
    jni_CallCharMethodV,
    jni_CallCharMethodA,

    // 46-48: CallShortMethod{,V,A}
    jni_CallShortMethod,
    jni_CallShortMethodV,
    jni_CallShortMethodA,

    // 49-51: CallIntMethod{,V,A}
    jni_CallIntMethod,
    jni_CallIntMethodV,
    jni_CallIntMethodA,

    // 52-54: CallLongMethod{,V,A}
    jni_CallLongMethod,
    jni_CallLongMethodV,
    jni_CallLongMethodA,

    // 55-57: CallFloatMethod{,V,A}
    jni_CallFloatMethod,
    jni_CallFloatMethodV,
    jni_CallFloatMethodA,

    // 58-60: CallDoubleMethod{,V,A}
    jni_CallDoubleMethod,
    jni_CallDoubleMethodV,
    jni_CallDoubleMethodA,

    // 61-63: CallVoidMethod{,V,A}
    jni_CallVoidMethod,
    jni_CallVoidMethodV,
    jni_CallVoidMethodA,

    // 64-66: CallNonvirtualObjectMethod{,V,A}
    jni_CallNonvirtualObjectMethod,
    jni_CallNonvirtualObjectMethodV,
    jni_CallNonvirtualObjectMethodA,

    // 67-69: CallNonvirtualBooleanMethod{,V,A}
    jni_CallNonvirtualBooleanMethod,
    jni_CallNonvirtualBooleanMethodV,
    jni_CallNonvirtualBooleanMethodA,

    // 70-72: CallNonvirtualByteMethod{,V,A}
    jni_CallNonvirtualByteMethod,
    jni_CallNonvirtualByteMethodV,
    jni_CallNonvirtualByteMethodA,

    // 73-75: CallNonvirtualCharMethod{,V,A}
    jni_CallNonvirtualCharMethod,
    jni_CallNonvirtualCharMethodV,
    jni_CallNonvirtualCharMethodA,

    // 76-78: CallNonvirtualShortMethod{,V,A}
    jni_CallNonvirtualShortMethod,
    jni_CallNonvirtualShortMethodV,
    jni_CallNonvirtualShortMethodA,

    // 79-81: CallNonvirtualIntMethod{,V,A}
    jni_CallNonvirtualIntMethod,
    jni_CallNonvirtualIntMethodV,
    jni_CallNonvirtualIntMethodA,

    // 82-84: CallNonvirtualLongMethod{,V,A}
    jni_CallNonvirtualLongMethod,
    jni_CallNonvirtualLongMethodV,
    jni_CallNonvirtualLongMethodA,

    // 85-87: CallNonvirtualFloatMethod{,V,A}
    jni_CallNonvirtualFloatMethod,
    jni_CallNonvirtualFloatMethodV,
    jni_CallNonvirtualFloatMethodA,

    // 88-90: CallNonvirtualDoubleMethod{,V,A}
    jni_CallNonvirtualDoubleMethod,
    jni_CallNonvirtualDoubleMethodV,
    jni_CallNonvirtualDoubleMethodA,

    // 91-93: CallNonvirtualVoidMethod{,V,A}
    jni_CallNonvirtualVoidMethod,
    jni_CallNonvirtualVoidMethodV,
    jni_CallNonvirtualVoidMethodA,

    // 94: GetFieldID
    jni_GetFieldID,

    // 95-103: Get<Type>Field
    jni_GetObjectField,
    jni_GetBooleanField,
    jni_GetByteField,
    jni_GetCharField,
    jni_GetShortField,
    jni_GetIntField,
    jni_GetLongField,
    jni_GetFloatField,
    jni_GetDoubleField,

    // 104-112: Set<Type>Field
    jni_SetObjectField,
    jni_SetBooleanField,
    jni_SetByteField,
    jni_SetCharField,
    jni_SetShortField,
    jni_SetIntField,
    jni_SetLongField,
    jni_SetFloatField,
    jni_SetDoubleField,

    // 113: GetStaticMethodID
    jni_GetStaticMethodID,

    // 114-116: CallStaticObjectMethod{,V,A}
    jni_CallStaticObjectMethod,
    jni_CallStaticObjectMethodV,
    jni_CallStaticObjectMethodA,

    // 117-119: CallStaticBooleanMethod{,V,A}
    jni_CallStaticBooleanMethod,
    jni_CallStaticBooleanMethodV,
    jni_CallStaticBooleanMethodA,

    // 120-122: CallStaticByteMethod{,V,A}
    jni_CallStaticByteMethod,
    jni_CallStaticByteMethodV,
    jni_CallStaticByteMethodA,

    // 123-125: CallStaticCharMethod{,V,A}
    jni_CallStaticCharMethod,
    jni_CallStaticCharMethodV,
    jni_CallStaticCharMethodA,

    // 126-128: CallStaticShortMethod{,V,A}
    jni_CallStaticShortMethod,
    jni_CallStaticShortMethodV,
    jni_CallStaticShortMethodA,

    // 129-131: CallStaticIntMethod{,V,A}
    jni_CallStaticIntMethod,
    jni_CallStaticIntMethodV,
    jni_CallStaticIntMethodA,

    // 132-134: CallStaticLongMethod{,V,A}
    jni_CallStaticLongMethod,
    jni_CallStaticLongMethodV,
    jni_CallStaticLongMethodA,

    // 135-137: CallStaticFloatMethod{,V,A}
    jni_CallStaticFloatMethod,
    jni_CallStaticFloatMethodV,
    jni_CallStaticFloatMethodA,

    // 138-140: CallStaticDoubleMethod{,V,A}
    jni_CallStaticDoubleMethod,
    jni_CallStaticDoubleMethodV,
    jni_CallStaticDoubleMethodA,

    // 141-143: CallStaticVoidMethod{,V,A}
    jni_CallStaticVoidMethod,
    jni_CallStaticVoidMethodV,
    jni_CallStaticVoidMethodA,

    // 144: GetStaticFieldID
    jni_GetStaticFieldID,

    // 145-153: GetStatic<Type>Field
    jni_GetStaticObjectField,
    jni_GetStaticBooleanField,
    jni_GetStaticByteField,
    jni_GetStaticCharField,
    jni_GetStaticShortField,
    jni_GetStaticIntField,
    jni_GetStaticLongField,
    jni_GetStaticFloatField,
    jni_GetStaticDoubleField,

    // 154-162: SetStatic<Type>Field
    jni_SetStaticObjectField,
    jni_SetStaticBooleanField,
    jni_SetStaticByteField,
    jni_SetStaticCharField,
    jni_SetStaticShortField,
    jni_SetStaticIntField,
    jni_SetStaticLongField,
    jni_SetStaticFloatField,
    jni_SetStaticDoubleField,

    // 163: NewString
    jni_NewString,
    // 164: GetStringLength
    jni_GetStringLength,
    // 165: GetStringChars
    jni_GetStringChars,
    // 166: ReleaseStringChars
    jni_ReleaseStringChars,

    // 167: NewStringUTF
    jni_NewStringUTF,
    // 168: GetStringUTFLength
    jni_GetStringUTFLength,
    // 169: GetStringUTFChars
    jni_GetStringUTFChars,
    // 170: ReleaseStringUTFChars
    jni_ReleaseStringUTFChars,

    // 171: GetArrayLength
    jni_GetArrayLength,

    // 172: NewObjectArray
    jni_NewObjectArray,
    // 173: GetObjectArrayElement
    jni_GetObjectArrayElement,
    // 174: SetObjectArrayElement
    jni_SetObjectArrayElement,

    // 175-182: New<Type>Array
    jni_NewBooleanArray,
    jni_NewByteArray,
    jni_NewCharArray,
    jni_NewShortArray,
    jni_NewIntArray,
    jni_NewLongArray,
    jni_NewFloatArray,
    jni_NewDoubleArray,

    // 183-190: Get<Type>ArrayElements
    jni_GetBooleanArrayElements,
    jni_GetByteArrayElements,
    jni_GetCharArrayElements,
    jni_GetShortArrayElements,
    jni_GetIntArrayElements,
    jni_GetLongArrayElements,
    jni_GetFloatArrayElements,
    jni_GetDoubleArrayElements,

    // 191-198: Release<Type>ArrayElements
    jni_ReleaseBooleanArrayElements,
    jni_ReleaseByteArrayElements,
    jni_ReleaseCharArrayElements,
    jni_ReleaseShortArrayElements,
    jni_ReleaseIntArrayElements,
    jni_ReleaseLongArrayElements,
    jni_ReleaseFloatArrayElements,
    jni_ReleaseDoubleArrayElements,

    // 199-214: Get/Set<Type>ArrayRegion
    jni_GetBooleanArrayRegion,
    jni_GetByteArrayRegion,
    jni_GetCharArrayRegion,
    jni_GetShortArrayRegion,
    jni_GetIntArrayRegion,
    jni_GetLongArrayRegion,
    jni_GetFloatArrayRegion,
    jni_GetDoubleArrayRegion,

    jni_SetBooleanArrayRegion,
    jni_SetByteArrayRegion,
    jni_SetCharArrayRegion,
    jni_SetShortArrayRegion,
    jni_SetIntArrayRegion,
    jni_SetLongArrayRegion,
    jni_SetFloatArrayRegion,
    jni_SetDoubleArrayRegion,

    // 215: RegisterNatives
    jni_RegisterNatives,
    // 216: UnregisterNatives
    jni_UnregisterNatives,

    // 217: MonitorEnter
    jni_MonitorEnter,
    // 218: MonitorExit
    jni_MonitorExit,

    // 219: GetJavaVM
    jni_GetJavaVM,

    // 220: GetStringRegion
    jni_GetStringRegion,
    // 221: GetStringUTFRegion
    jni_GetStringUTFRegion,

    // 222: GetPrimitiveArrayCritical
    jni_GetPrimitiveArrayCritical,
    // 223: ReleasePrimitiveArrayCritical
    jni_ReleasePrimitiveArrayCritical,

    // 224: GetStringCritical
    jni_GetStringCritical,
    // 225: ReleaseStringCritical
    jni_ReleaseStringCritical,

    // 226: NewWeakGlobalRef
    jni_NewWeakGlobalRef,
    // 227: DeleteWeakGlobalRef
    jni_DeleteWeakGlobalRef,

    // 228: ExceptionCheck
    jni_ExceptionCheck,

    // 229: NewDirectByteBuffer
    jni_NewDirectByteBuffer,
    // 230: GetDirectBufferAddress
    jni_GetDirectBufferAddress,
    // 231: GetDirectBufferCapacity
    jni_GetDirectBufferCapacity,

    // 232: GetObjectRefType (JNI 1.6)
    jni_GetObjectRefType,
};

// ============================================================================
// The singleton JNIEnv pointer (points to the function table pointer)
// ============================================================================
static const struct JNINativeInterface_ *g_env_ptr = &g_jni_functions;

// ============================================================================
// Public API
// ============================================================================

DxResult dx_jni_init(DxVM *vm) {
    if (!vm) return DX_ERR_NULL_PTR;
    g_vm = vm;
    DX_INFO(TAG, "JNI environment initialized (JNI 1.6, %zu functions)",
            sizeof(g_jni_functions) / sizeof(void *));
    return DX_OK;
}

JNIEnv *dx_jni_get_env(DxVM *vm) {
    (void)vm;
    return (JNIEnv *)&g_env_ptr;
}

void dx_jni_destroy(DxVM *vm) {
    (void)vm;
    g_vm = NULL;
    DX_INFO(TAG, "JNI environment destroyed");
}
