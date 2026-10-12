#include <jni.h>

extern jbyte blob[];
extern int blob_size;

/* legacy path kept for reference; streaming entry below is what Java calls */
JNIEXPORT jbyteArray JNICALL Java_com_termux_app_TermuxInstaller_getZip(JNIEnv *env, __attribute__((__unused__)) jobject This)
{
    jbyteArray ret = (*env)->NewByteArray(env, blob_size);
    (*env)->SetByteArrayRegion(env, ret, 0, blob_size, blob);
    return ret;
}

JNIEXPORT jint JNICALL Java_com_termux_app_TermuxInstaller_getZipSize(__attribute__((__unused__)) JNIEnv *env, __attribute__((__unused__)) jobject This)
{
    return blob_size;
}

/* dsh-android: copy `count` bytes of the embedded bootstrap at `off` into dst.
 * Chunked GetByteArrayRegion so the Java side never allocates a blob-sized
 * byte[] (a >200MB NewByteArray aborts with JNI "java_array == null" on low
 * heap ceilings). */
JNIEXPORT jint JNICALL Java_com_termux_app_TermuxInstaller_copyBytes(JNIEnv *env, __attribute__((__unused__)) jobject This,
    jlong off, jbyteArray dst, jint doff, jint count)
{
    if (off < 0 || off >= blob_size || count <= 0) return 0;
    jint avail = blob_size - (jint)off;
    if (count > avail) count = avail;
    if (doff < 0 || doff + count > (*env)->GetArrayLength(env, dst)) return -1;
    (*env)->SetByteArrayRegion(env, dst, doff, count, blob + off);
    return count;
}
