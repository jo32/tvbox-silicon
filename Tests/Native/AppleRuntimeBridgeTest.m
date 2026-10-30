#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

extern char *TVAppleRuntimeRequest(const char *, const char *);
static const char *resources;

// Expects the exact response, or a localized embedded_request error when `expected` is NULL.
static void check(const char *input, const char *expected) {
    char *response = TVAppleRuntimeRequest(resources, input);
    NSCAssert(response != NULL, @"Missing native response");
    NSData *data = [NSData dataWithBytes:response length:strlen(response)];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSCAssert([json isKindOfClass:NSDictionary.class], @"Invalid JSON response: %@", @(response));
    if (!expected) {
        NSCAssert([json[@"error"] isKindOfClass:NSString.class], @"Missing error: %@", json);
        NSCAssert([json[@"errorCode"] isEqual:@"embedded_request"], @"Missing localized error code: %@", json);
    } else {
        NSCAssert(strcmp(expected, response) == 0, @"Expected %@, got %@", @(expected), @(response));
    }
    free(response);
}

static void *run(void *unused) {
    @autoreleasepool {
        // TestFlight build 29 crashed at strdup(text.UTF8String) for unpaired surrogates in Java text.
        // They become U+FFFD (EF BF BD) and the rest of the response is kept.
        check("high-surrogate", "{\"result\":\"\xEF\xBF\xBD\"}");
        check("low-surrogate", "{\"result\":\"\xEF\xBF\xBD\"}");
        check("cut-emoji", "{\"result\":\"😀\xEF\xBF\xBD\"}");
        check("reversed-pair", "{\"result\":\"\xEF\xBF\xBD\xEF\xBF\xBD\"}");
        check("exception", NULL);
        check("out-of-memory", NULL);
        check("no-response", NULL);
        // The JVM got the bridge's options: 128 MB of class space, which 3 GB devices can reserve.
        check("class-space", "{\"result\":\"134217728\"}");
        check(NULL, NULL);
        check("\xff", NULL);
        const char *valid[] = {"{\"result\":\"中文、日本語、😀 and \\u0000\"}", "{\"result\":\"\"}", "{\"result\":\"recovered\"}"};
        for (int i = 0; i < 3; i++) check(valid[i], valid[i]);
    }
    return NULL;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSCAssert(argc == 2, @"Expected fixture resource directory");
        resources = argv[1];
        // Exercise concurrent startup, attaching new workers, and recovery after exceptions.
        pthread_t workers[5];
        for (int i = 0; i < 5; i++) NSCAssert(pthread_create(&workers[i], NULL, run, NULL) == 0, @"Could not start worker");
        for (int i = 0; i < 5; i++) NSCAssert(pthread_join(workers[i], NULL) == 0, @"Could not join worker");
        puts("Apple runtime JNI bridge tests passed");
    }
}
