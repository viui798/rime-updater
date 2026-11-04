package com.viui798.rime_updater;
import android.os.ParcelFileDescriptor;
interface IRimeFiles {
    void destroy() = 16777114;
    String inspect(String root) = 1;
    String files(String root) = 2;
    String discoverRoots(String root) = 5;
    ParcelFileDescriptor read(String root, String relative) = 3;
    String commit(String root, in ParcelFileDescriptor bundle) = 4;
}
