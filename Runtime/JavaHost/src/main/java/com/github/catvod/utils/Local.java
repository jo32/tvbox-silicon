// Adapted from FongMi/TV catvod (GPL-3.0), commit 4512b4c: the host side of FongMi's new spider SDK (#500).
package com.github.catvod.utils;

import android.content.Context;
import android.content.SharedPreferences;


import com.github.catvod.Runtime;


public final class Local {

    private final String name;

    public Local(String siteKey) {
        if (siteKey == null || siteKey.isEmpty()) throw new IllegalArgumentException("Local requires a site key");
        name = "spider_local_" + Crypto.sha256(siteKey);
    }

    public String get(String key) {
        return getPrefs().getString(key(key), null);
    }

    public void set(String key, String value) {
        Json.strict(value);
        getPrefs().edit().putString(key(key), value).apply();
    }

    public void delete(String key) {
        getPrefs().edit().remove(key(key)).apply();
    }

    public void clear() {
        getPrefs().edit().clear().apply();
    }

    private SharedPreferences getPrefs() {
        return Runtime.context().getSharedPreferences(name, 0);
    }

    private String key(String key) {
        if (key == null || key.isEmpty()) throw new IllegalArgumentException("Local requires a nonempty key");
        return key;
    }
}
