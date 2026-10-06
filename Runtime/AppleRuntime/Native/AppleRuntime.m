#import <Foundation/Foundation.h>
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

// Called from the app's plugin worker threads (several at once for searches), never the UI thread.
// Only VM startup needs a lock; each later call attaches its own thread.
static pthread_mutex_t startLock = PTHREAD_MUTEX_INITIALIZER;
static JavaVM *runtimeVM;
static jclass bootstrap;
static jmethodID requestMethod;
static BOOL failed;
static char *failure(const char *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"error": @(message)} options:0 error:NULL];
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
char *TVAppleRuntimeRequest(const char *resourcePath, const char *requestJSON) {
    @autoreleasepool {
        if (failed) return failure("The plugin runtime failed. Restart the app to retry.");
        JNIEnv *env = NULL;
        pthread_mutex_lock(&startLock);
        if (!runtimeVM) {
            NSString *root = @(resourcePath);
            NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            NSString *log = [cache stringByAppendingPathComponent:@"embedded-jvm.log"];
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:log error:NULL];
            freopen(log.UTF8String, [attributes fileSize] > 2 * 1024 * 1024 ? "w" : "a", stderr);
            setbuf(stderr, NULL);
            fprintf(stderr, "Starting on-device Java runtime\n");
            NSString *host = [root stringByAppendingPathComponent:@"JavaHost"];
            NSString *classpath = [host stringByAppendingPathComponent:@"apple-bindings.jar"];
            classpath = [classpath stringByAppendingFormat:@":%@", [host stringByAppendingPathComponent:@"host.jar"]];
            for (NSString *file in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[host stringByAppendingPathComponent:@"lib"] error:NULL] sortedArrayUsingSelector:@selector(compare:)]) {
                if ([file.pathExtension isEqualToString:@"jar"]) classpath = [classpath stringByAppendingFormat:@":%@/lib/%@", host, file];
            }
            NSArray<NSString *> *arguments = @[@"-Xmx512m", @"-Xms32m", @"-Xss2m", @"-XX:+UseSerialGC", @"-XX:+DisableAttachMechanism", @"-Xrs",
                @"--add-opens=java.base/java.lang=ALL-UNNAMED", @"--enable-native-access=ALL-UNNAMED",
                @"-Dorg.slf4j.simpleLogger.defaultLogLevel=error",
                [@"-Djava.home=" stringByAppendingString:[root stringByAppendingPathComponent:@"lib"]],
                [@"-Djava.class.path=" stringByAppendingString:classpath],
                [@"-Djava.io.tmpdir=" stringByAppendingString:NSTemporaryDirectory()]];
            JavaVMOption options[arguments.count];
            for (NSUInteger i=0;i<arguments.count;i++) { options[i].optionString=(char *)arguments[i].UTF8String; options[i].extraInfo=NULL; }
            JavaVMInitArgs init={.version=JNI_VERSION_1_8,.nOptions=(jint)arguments.count,.options=options,.ignoreUnrecognized=JNI_FALSE};
            jint status=JNI_CreateJavaVM(&runtimeVM,(void **)&env,&init);
            if (status != JNI_OK) { runtimeVM=NULL; failed=YES; pthread_mutex_unlock(&startLock); return failure("Could not start the embedded Java runtime."); }
            jclass local=(*env)->FindClass(env,"tvbox/runtime/AppleBootstrap");
            if (local) { bootstrap=(*env)->NewGlobalRef(env,local); (*env)->DeleteLocalRef(env,local); }
            if (bootstrap) requestMethod=(*env)->GetStaticMethodID(env,bootstrap,"request","(Ljava/lang/String;)Ljava/lang/String;");
        }
        pthread_mutex_unlock(&startLock);
        if (!env && (*runtimeVM)->AttachCurrentThread(runtimeVM,(void **)&env,NULL) != JNI_OK) {
            return failure("Could not attach the plugin worker.");
        }
        if ((*env)->ExceptionCheck(env) || !requestMethod) {
            (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); failed=YES;
            return failure("Could not initialize the plugin libraries. See diagnostic logs.");
        }
        NSString *requestText = @(requestJSON);
        NSUInteger length = requestText.length;
        unichar *characters = malloc((length + 1) * sizeof(unichar));
        [requestText getCharacters:characters range:NSMakeRange(0,length)];
        jstring input=(*env)->NewString(env,(const jchar *)characters,(jsize)length);
        free(characters);
        jstring output=(jstring)(*env)->CallStaticObjectMethod(env,bootstrap,requestMethod,input);
        (*env)->DeleteLocalRef(env,input);
        char *result=NULL;
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env);
            result=failure("The embedded plugin request failed. See diagnostic logs.");
        } else if(output) {
            const jchar *characters=(*env)->GetStringChars(env,output,NULL);
            NSString *text=[[NSString alloc] initWithCharacters:(const unichar *)characters length:(NSUInteger)(*env)->GetStringLength(env,output)];
            result=strdup(text.UTF8String);
            (*env)->ReleaseStringChars(env,output,characters); (*env)->DeleteLocalRef(env,output);
        } else result=failure("The plugin returned no response.");
        (*runtimeVM)->DetachCurrentThread(runtimeVM);
        return result;
    }
}
