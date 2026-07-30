#import <Cocoa/Cocoa.h>

// Some private +[NSCursor _fooCursor] selectors pass respondsToSelector: but
// throw doesNotRecognizeSelector: from inside the implementation. Swift cannot
// catch ObjC exceptions, so the probe has to happen behind @try/@catch.
static inline NSCursor *_Nullable CursorShimTryFactory(NSString *_Nonnull selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![NSCursor respondsToSelector:selector]) { return nil; }
    NSCursor *result = nil;
    @try {
        IMP imp = [NSCursor methodForSelector:selector];
        if (imp == NULL) { return nil; }
        NSCursor *(*fn)(id, SEL) = (NSCursor *(*)(id, SEL))imp;
        id candidate = fn([NSCursor class], selector);
        if ([candidate isKindOfClass:[NSCursor class]]) { result = candidate; }
    }
    @catch (NSException *exception) {
        result = nil;
    }
    return result;
}
