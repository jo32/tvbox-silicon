#import <UIKit/UIKit.h>
#include <jni.h>
#include <unistd.h>

static void runJVM(void) {
    @autoreleasepool {
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:[documents stringByAppendingPathComponent:@"result.txt"] error:NULL];
        NSString *log = [documents stringByAppendingPathComponent:@"jvm.log"];
        freopen(log.UTF8String, "w", stdout);
        dup2(fileno(stdout), fileno(stderr));
        setbuf(stdout, NULL); setbuf(stderr, NULL);
        NSString *bundle = NSBundle.mainBundle.bundlePath;
        NSString *runtime = [bundle stringByAppendingPathComponent:@"lib"];
        NSString *classpath = [bundle stringByAppendingPathComponent:@"spike"];
        NSString *host = [bundle stringByAppendingPathComponent:@"host"];
        // Host stand-ins must precede Android's compile-time stub archive.
        classpath = [classpath stringByAppendingFormat:@":%@", [host stringByAppendingPathComponent:@"host.jar"]];
        for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:host error:NULL]) {
            if ([file.pathExtension isEqualToString:@"jar"] && ![file isEqualToString:@"host.jar"]) classpath = [classpath stringByAppendingFormat:@":%@", [host stringByAppendingPathComponent:file]];
        }
        NSArray<NSString *> *arguments = @[
            @"-Xmx512m", @"-Xms32m", @"-Xss2m", @"-XX:+UseSerialGC", @"-XX:+DisableAttachMechanism", @"-Xrs",
            [@"-Djava.home=" stringByAppendingString:runtime],
            [@"-Djava.class.path=" stringByAppendingString:classpath],
            [@"-Djava.io.tmpdir=" stringByAppendingString:NSTemporaryDirectory()]
        ];
        JavaVMOption options[arguments.count];
        for (NSUInteger i = 0; i < arguments.count; i++) { options[i].optionString = (char *)arguments[i].UTF8String; options[i].extraInfo = NULL; }
        JavaVMInitArgs init = { .version = JNI_VERSION_1_8, .nOptions = (jint)arguments.count, .options = options, .ignoreUnrecognized = JNI_FALSE };
        JavaVM *vm = NULL; JNIEnv *env = NULL;
        puts("Starting embedded Zero JVM");
        jint status = JNI_CreateJavaVM(&vm, (void **)&env, &init);
        NSString *result = [NSString stringWithFormat:@"JNI_CreateJavaVM returned %d", status];
        if (status == JNI_OK) {
            jclass cls = (*env)->FindClass(env, "RuntimeSpike");
            NSString *archive = [bundle stringByAppendingPathComponent:@"plugin.jar"];
            BOOL conversion = [[NSFileManager defaultManager] fileExistsAtPath:archive];
            jmethodID method = cls ? (*env)->GetStaticMethodID(env, cls, conversion ? "convert" : "run",
                conversion ? "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;" : "()Ljava/lang/String;") : NULL;
            jstring value = NULL;
            if (method && conversion) {
                jstring input = (*env)->NewStringUTF(env, archive.UTF8String);
                jstring cache = (*env)->NewStringUTF(env, documents.UTF8String);
                value = (jstring)(*env)->CallStaticObjectMethod(env, cls, method, input, cache);
                (*env)->DeleteLocalRef(env, input); (*env)->DeleteLocalRef(env, cache);
            } else if (method) value = (jstring)(*env)->CallStaticObjectMethod(env, cls, method);
            if ((*env)->ExceptionCheck(env)) {
                (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env);
                result = @"Java spike failed; see jvm.log";
            } else if (value) {
                const char *text = (*env)->GetStringUTFChars(env, value, NULL);
                result = [NSString stringWithUTF8String:text];
                (*env)->ReleaseStringUTFChars(env, value, text);
            }
            (*vm)->DetachCurrentThread(vm);
        }
        fprintf(stdout, "%s\n", result.UTF8String);
        [result writeToFile:[documents stringByAppendingPathComponent:@"result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RuntimeResult" object:result];
        });
    }
}

@interface SpikeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *label;
@end

@implementation SpikeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.blackColor;
    self.label = [[UILabel alloc] initWithFrame:CGRectInset(self.window.bounds, 30, 80)];
    self.label.numberOfLines = 0; self.label.textColor = UIColor.whiteColor;
    self.label.text = @"Testing the embedded JVM…";
    [controller.view addSubview:self.label];
    self.window.rootViewController = controller; [self.window makeKeyAndVisible];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showResult:) name:@"RuntimeResult" object:nil];
    NSThread *thread = [[NSThread alloc] initWithBlock:^{ runJVM(); }];
    thread.stackSize = 8 * 1024 * 1024; [thread start];
}
- (void)showResult:(NSNotification *)notification { self.label.text = notification.object; }
@end

@interface SpikeDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation SpikeDelegate
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(SpikeDelegate.class)); }
}
