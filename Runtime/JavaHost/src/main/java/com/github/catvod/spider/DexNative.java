package com.github.catvod.spider;
import tvbox.runtime.NativeCalls;
/** JNI transport to the original Android library running in the local guest CPU. */
public final class DexNative {
    public static String encrypt(String value) { return (String) NativeCalls.invoke("encrypt(Ljava/lang/String;)Ljava/lang/String;",value); }
    public static String decrypt(String value) { return (String) NativeCalls.invoke("decrypt(Ljava/lang/String;)Ljava/lang/String;",value); }
    public static String native_ting_md5(String value) { return (String) NativeCalls.invoke("native_ting_md5(Ljava/lang/String;)Ljava/lang/String;",value); }
    public static String noxSign(String a,String b,String c) { return (String) NativeCalls.invoke("noxSign(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",a,b,c); }
    public static Object getLoader(Object value) { return NativeCalls.invoke("getLoader(Ljava/lang/Object;)Ljava/lang/Object;",value); }
    public static Object getSpider(Object loader,String name) { return NativeCalls.invoke("getSpider(Ljava/lang/Object;Ljava/lang/String;)Ljava/lang/Object;",loader,name); }
    public static int[] calcResult(int[] value) { return (int[])NativeCalls.invoke("calcResult([I)[I",value); }
    public static Object[] proxyInvoke(Object loader,Object params) { return (Object[])NativeCalls.invoke("proxyInvoke(Ljava/lang/Object;Ljava/lang/Object;)[Ljava/lang/Object;",loader,params); }
}
