//
//  DelegateDispatch.m
//  DelegateDispatch
//
//  Created by xiabob on 2017/12/19.
//  Copyright © 2017年 xiabob. All rights reserved.
//

#import "DelegateDispatch.h"
#import <objc/runtime.h>
@class DelegateMessageReplacer;

static NSString * const kDDHostAssociatedObjectKey = @"kDDHostAssociatedObjectKey";

static const char * delegate_dispatch_unique_key(id host, Protocol *protocol) {
    return [NSString stringWithFormat:@"%p_%s", host, protocol_getName(protocol)].UTF8String;
}

@interface DelegateDispatch ()

@property (nonatomic, strong) NSMapTable *delegateMap;

- (void)removeDelegateClientsForUniqueKey:(NSString *)uniqueKey;

@end

@interface DelegateMessageReplacer: NSObject

@property (nonatomic,   weak) id host;
@property (nonatomic, strong) Protocol *protocol;
@property (nonatomic, strong) NSHashTable *clientList;

- (void)cleanBeforeMessageInfoDealloc:(NSString *)uniqueKey;

@end


@interface DelegateMessageInfo: NSObject

@property (nonatomic, copy) NSString *uniqueKey;
@property (nonatomic, weak) DelegateMessageReplacer *messageReplacer;

@end


@implementation DelegateMessageInfo

- (instancetype)initWithMessageReplacer:(DelegateMessageReplacer *)messageReplacer andUniqueKey:(NSString *)key {
    if (self = [super init]) {
        self.messageReplacer = messageReplacer;
        self.uniqueKey = key;
    }
    
    return self;
}

- (void)dealloc {
    //need clean messageReplacer
    [self.messageReplacer cleanBeforeMessageInfoDealloc:self.uniqueKey];
}

@end


@implementation DelegateMessageReplacer

- (instancetype)initWithHost:(id)host protocol:(Protocol *)protocol delegateSetter:(SEL)selector {
    if (self = [super init]) {
        self.host = host;
        self.protocol = protocol;
        self.clientList = [NSHashTable hashTableWithOptions:NSHashTableWeakMemory | NSHashTableObjectPointerPersonality];
        
        [self configWithHost:host protocol:protocol delegateSetter:selector];
    }
    
    return self;
}

- (void)configWithHost:(id)host protocol:(Protocol *)protocol delegateSetter:(SEL)selector {
    
    //when host dealloc, the associated object will dealloc. http://yulingtianxia.com/blog/2017/12/15/Associated-Object-and-Dealloc/
    DelegateMessageInfo *info = [[DelegateMessageInfo alloc] initWithMessageReplacer:self andUniqueKey:[self uniqueKeyFrom:host protocol:protocol]];
    objc_setAssociatedObject(host, &kDDHostAssociatedObjectKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    Class cls = object_getClass(host);
    Method originMethod = class_getInstanceMethod(cls, selector);
    const char* originTypeEncoding = method_getTypeEncoding(originMethod);
    
    //invoke set delegate method
    ((void (*)(id, SEL, id))[host methodForSelector:selector])(host, selector, self);
    
    //replace set delegate method
    IMP xb_setDelegate = [self methodForSelector:@selector(__xb_setDelegate:)];
    IMP xb_delegateSetterMethod = class_replaceMethod(cls, selector, xb_setDelegate, originTypeEncoding);
    if (xb_delegateSetterMethod) {
        class_addMethod(cls, @selector(__xb_setDelegate:), xb_delegateSetterMethod, originTypeEncoding);
    }
}

- (void)addDelegateClient:(id)client forHost:(id)host withProtocol:(Protocol *)protocol {
    if (![[self uniqueKeyFrom:self.host protocol:self.protocol] isEqualToString:[self uniqueKeyFrom:host protocol:protocol]]) return;
    
    if (client && ![self.clientList containsObject:client]) {
        [self.clientList addObject:client];
    }
}

- (NSString *)uniqueKeyFrom:(id)host protocol:(Protocol *)protocol {
    return [NSString stringWithFormat:@"%s", delegate_dispatch_unique_key(host, protocol)];
}

- (void)cleanBeforeMessageInfoDealloc:(NSString *)uniqueKey {
    [[DelegateDispatch shareInstance] removeDelegateClientsForUniqueKey:uniqueKey];
}

#pragma mark - Message Forward

- (BOOL)respondsToSelector:(SEL)aSelector {
    unsigned int methodCount = 0;
    struct objc_method_description *methods = protocol_copyMethodDescriptionList(self.protocol, NO, YES, &methodCount);
    for (int i = 0; i < methodCount; i++) {
        struct objc_method_description methodDescription = methods[i];
        if (sel_isEqual(methodDescription.name, aSelector)) {
            free(methods);
            
            return YES;
        }
    }
    
    free(methods);
    
    return NO;
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    return protocol_isEqual(self.protocol, aProtocol);
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    unsigned int methodCount = 0;
    struct objc_method_description *methods = protocol_copyMethodDescriptionList(self.protocol, NO, YES, &methodCount);
    for (int i = 0; i < methodCount; i++) {
        struct objc_method_description methodDescription = methods[i];
        if (sel_isEqual(methodDescription.name, aSelector)) {
            free(methods);
            
            return [NSMethodSignature signatureWithObjCTypes:methodDescription.types];
        }
    }
    
    free(methods);
    
    return [super methodSignatureForSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    for (id client in self.clientList) {
        if ([client respondsToSelector:anInvocation.selector]) {
            anInvocation.target = client;
            [anInvocation invoke];
        }
    }
}

#pragma mark - Override setDelegate

- (void)__xb_setDelegate:(id)delegate {
    if ([delegate isKindOfClass:[DelegateDispatch class]] || [delegate isKindOfClass:[DelegateMessageReplacer class]]) {
        return;
    }
    
    //Important: here, self means host object
    DelegateMessageInfo *info = objc_getAssociatedObject(self, &kDDHostAssociatedObjectKey);
    if (info) {
        [info.messageReplacer addDelegateClient:delegate forHost:self withProtocol:info.messageReplacer.protocol];
    }
}

@end



@implementation DelegateDispatch

+ (instancetype)shareInstance {
    static dispatch_once_t token;
    static DelegateDispatch *instance;
    dispatch_once(&token, ^{
        instance = [DelegateDispatch new];
    });
    
    return instance;
}

- (void)configDelegateDispatchWithHost:(id)host protocol:(Protocol *)protocol delegateSetter:(SEL)selector delegateObject:(id)delegate {
    //did config this host with same protocol, just return
    if ([self didConfigHost:host withProtocol:protocol]) return;
    
    NSString *key = [self delegateKeyForHost:host protocol:protocol];
    DelegateMessageReplacer *messageReplacer = [[DelegateMessageReplacer alloc] initWithHost:host protocol:protocol delegateSetter:selector];
    [self.delegateMap setObject:messageReplacer forKey:key];
    
    if (delegate) {
        [messageReplacer addDelegateClient:delegate forHost:host withProtocol:protocol];
    }
    
}

- (void)addDelegateClient:(id)client forHost:(id)host withProtocol:(Protocol *)protocol {
    NSAssert([self didConfigHost:host withProtocol:protocol], @"You must call 'configDelegateDispatchWithHost' method at first!");
    
    if (host == nil || ![client conformsToProtocol:protocol]) return;
    
    NSString *key = [self delegateKeyForHost:host protocol:protocol];
    DelegateMessageReplacer *messageReplacer = [self.delegateMap objectForKey:key];
    [messageReplacer addDelegateClient:client forHost:host withProtocol:protocol];
}

- (void)removeDelegateClient:(id)client forHost:(id)host withProtocol:(Protocol *)protocol {
    NSString *key = [self delegateKeyForHost:host protocol:protocol];
    DelegateMessageReplacer *messageReplacer = [self.delegateMap objectForKey:key];
    [messageReplacer.clientList removeObject:client];
}

- (void)removeAllDelegateClients:(id)client forHost:(id)host withProtocol:(Protocol *)protocol {
    NSString *key = [self delegateKeyForHost:host protocol:protocol];
    [self removeDelegateClientsForUniqueKey:key];
}

#pragma mark - Private

- (void)removeDelegateClientsForUniqueKey:(NSString *)uniqueKey {
    [self.delegateMap removeObjectForKey:uniqueKey];
}

- (BOOL)didConfigHost:(id)host withProtocol:(Protocol *)protocol {
    NSString *delegateKey = [self delegateKeyForHost:host protocol:protocol];
    return [self.delegateMap.keyEnumerator.allObjects containsObject:delegateKey];
}

- (NSString *)delegateKeyForHost:(id)host protocol:(Protocol *)protocol  {
    return [NSString stringWithFormat:@"%s", delegate_dispatch_unique_key(host, protocol)];
}

#pragma mark - Getter

- (NSMapTable *)delegateMap {
    if (!_delegateMap) {
        _delegateMap = [NSMapTable mapTableWithKeyOptions:NSMapTableCopyIn valueOptions:NSMapTableStrongMemory | NSMapTableObjectPointerPersonality];
    }
    
    return _delegateMap;
}

@end

