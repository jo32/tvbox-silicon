package android.os;

import java.io.File;

/** Filesystem statistics from java.io.File; plugins size their image and data caches with it. */
public class StatFs {
    private static final long BLOCK = 4096;
    private File root;

    public StatFs(String path) { restat(path); }
    public void restat(String path) { root = new File(path); }

    public long getTotalBytes() { return root.getTotalSpace(); }
    public long getFreeBytes() { return root.getFreeSpace(); }
    public long getAvailableBytes() { return root.getUsableSpace(); }
    public long getBlockSizeLong() { return BLOCK; }
    public long getBlockCountLong() { return getTotalBytes() / BLOCK; }
    public long getFreeBlocksLong() { return getFreeBytes() / BLOCK; }
    public long getAvailableBlocksLong() { return getAvailableBytes() / BLOCK; }
    @Deprecated public int getBlockSize() { return (int) BLOCK; }
    @Deprecated public int getBlockCount() { return (int) Math.min(Integer.MAX_VALUE, getBlockCountLong()); }
    @Deprecated public int getFreeBlocks() { return (int) Math.min(Integer.MAX_VALUE, getFreeBlocksLong()); }
    @Deprecated public int getAvailableBlocks() { return (int) Math.min(Integer.MAX_VALUE, getAvailableBlocksLong()); }
}
