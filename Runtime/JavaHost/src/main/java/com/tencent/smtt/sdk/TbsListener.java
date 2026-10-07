package com.tencent.smtt.sdk;

public interface TbsListener {
    void onDownloadFinish(int code);
    void onInstallFinish(int code);
    void onDownloadProgress(int progress);
}
