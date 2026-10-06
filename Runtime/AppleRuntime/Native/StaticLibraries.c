#include <jni.h>
extern jint TVJNA_OnLoad(JavaVM *, void *);
extern jint TVUnicorn_OnLoad(JavaVM *, void *);
JNIEXPORT jint JNICALL JNI_OnLoad_jnidispatch(JavaVM *vm, void *reserved) {
    return TVJNA_OnLoad(vm, reserved) > 0 ? JNI_VERSION_1_8 : JNI_ERR;
}
JNIEXPORT jint JNICALL JNI_OnLoad_unicorn(JavaVM *vm, void *reserved) {
    return TVUnicorn_OnLoad(vm, reserved) > 0 ? JNI_VERSION_1_8 : JNI_ERR;
}
JNIEXPORT jint JNICALL JNI_OnLoad_disassembler(JavaVM *vm, void *reserved) { return JNI_VERSION_1_8; }
