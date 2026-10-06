package android.util;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.function.Consumer;

/** Android's write-to-".new"-then-rename file, including recovery of the pre-S ".bak" backup. */
public class AtomicFile {
    private final File baseName, newName, legacyBackupName;

    public AtomicFile(File baseName) { this(baseName, null); }
    public AtomicFile(File baseName, String commitTag) {
        this.baseName = baseName;
        newName = new File(baseName.getPath() + ".new");
        legacyBackupName = new File(baseName.getPath() + ".bak");
    }

    public File getBaseFile() { return baseName; }

    public void delete() { baseName.delete(); newName.delete(); legacyBackupName.delete(); }

    public FileOutputStream startWrite() throws IOException { return startWrite(0); }
    public FileOutputStream startWrite(long startTime) throws IOException {
        if (legacyBackupName.exists()) rename(legacyBackupName, baseName);
        try { return new FileOutputStream(newName); }
        catch (FileNotFoundException missingParent) {
            File parent = newName.getParentFile();
            if (parent == null || !(parent.mkdirs() || parent.isDirectory())) throw new IOException("Failed to create directory for " + newName);
            return new FileOutputStream(newName);
        }
    }

    public void finishWrite(FileOutputStream stream) {
        if (stream == null) return;
        if (!sync(stream)) Log.e("AtomicFile", "Failed to sync file output stream");
        try { stream.close(); } catch (IOException ignored) { }
        try { rename(newName, baseName); } catch (IOException failed) { Log.e("AtomicFile", "Failed to commit " + baseName + ": " + failed); }
    }

    public void failWrite(FileOutputStream stream) {
        if (stream == null) return;
        sync(stream);
        try { stream.close(); } catch (IOException ignored) { }
        newName.delete();
    }

    public FileInputStream openRead() throws FileNotFoundException {
        if (legacyBackupName.exists()) {
            try { rename(legacyBackupName, baseName); } catch (IOException ignored) { }
        }
        // An unfinished write leaves ".new" beside the committed file; the committed file wins.
        if (newName.exists() && baseName.exists()) newName.delete();
        return new FileInputStream(baseName);
    }

    public boolean exists() { return baseName.exists() || legacyBackupName.exists(); }

    public long getLastModifiedTime() {
        return (legacyBackupName.exists() ? legacyBackupName : baseName).lastModified();
    }

    public byte[] readFully() throws IOException {
        try (FileInputStream stream = openRead()) { return stream.readAllBytes(); }
    }

    public void write(Consumer<FileOutputStream> writeContent) {
        FileOutputStream stream = null;
        try {
            stream = startWrite();
            writeContent.accept(stream);
            finishWrite(stream);
        } catch (Throwable failed) {
            failWrite(stream);
            throw new RuntimeException("Failed to write " + baseName, failed);
        }
    }

    @Override public String toString() { return "AtomicFile[" + baseName + "]"; }

    private static boolean sync(FileOutputStream stream) {
        try { stream.getFD().sync(); return true; } catch (IOException failed) { return false; }
    }

    private static void rename(File source, File target) throws IOException {
        Files.move(source.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
    }
}
