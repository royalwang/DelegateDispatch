//
//  DelegateDispatch.m
//  DelegateDispatch
//
//  Created by xiabob on 2017/12/19.
//  Copyright © 2017年 xiabob. All rights reserved.
//

#import "DelegateDispatch.h"
#import <objc/runtime.h>

static NSString * const kDDSeparatedString = @"_";

@interface DelegateDispatch ()

@property (nonatomic, strong) NSMapTable *delegateMap;
@property (nonatomic, strong) NSMapTable *protocolToDelegateMap;

@property (nonatomic, strong) NSHashTable *delegateDisableDic;

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
    
    Class cls = object_getClass(host);
    Method originMethod = class_getInstanceMethod(cls, selector);
    const char* originTypeEncoding = method_getTypeEncoding(originMethod);
    
    [self.protocolToDelegateMap setObject:[self protocolToDelegateObjectForHost:host protocol:protocol] forKey:[self protocolToDelegateKeyForHost:host selector:selector]];
    
    if (delegate) {
        NSString *key = [self delegateKeyForHost:host protocol:protocol client:delegate];
        [self.delegateMap setObject:delegate forKey:key];
    }
    
    //invoke set delegate method
    ((void (*)(id, SEL, id))[host methodForSelector:selector])(host, selector, self);
    
    //replace set delegate method
    IMP xb_delegateSetterMethod = class_replaceMethod(cls, selector, (IMP)xb_setDelegate, originTypeEncoding);
    if (xb_delegateSetterMethod) {
        class_addMethod(cls, NSSelectorFromString(@"__xb_setDelegate:"), xb_delegateSetterMethod, originTypeEncoding);
    }
    
}

- (void)addDelegateWithHost:(id)host protocol:(Protocol *)protocol client:(id)client {
    NSAssert([self didConfigHost:host withProtocol:protocol], @"You must call 'configDelegateDispatchWithHost' method at first!");
    
    if (host == nil || ![client conformsToProtocol:protocol]) return;
    
    NSString *key = [self delegateKeyForHost:host protocol:protocol client:client];
    if (![self.delegateMap.keyEnumerator.allObjects containsObject:key]) {
        [self.delegateMap setObject:client forKey:key];
    }
}

- (void)setDelegateEnable:(BOOL)enable forClient:(id)client {
    if (enable) {
        [self.delegateDisableDic removeObject:client];
    } else {
        if (![self.delegateDisableDic containsObject:client]) {
            [self.delegateDisableDic addObject:client];
        }
    }
}

#pragma mark - Message Forwarding

- (BOOL)respondsToSelector:(SEL)aSelector {
    for (id client in self.delegateMap.objectEnumerator.allObjects) {
        if ([client respondsToSelector:aSelector]) {
            return YES;
        }
    }
    
    return NO;
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    for (NSString *object in self.protocolToDelegateMap.objectEnumerator.allObjects) {
        NSString *key = [object componentsSeparatedByString:kDDSeparatedString].lastObject;
        if ([key isEqualToString:[NSString stringWithUTF8String:protocol_getName(aProtocol)]]) {
            return YES;
        }
    }
    
    return NO;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    for (id client in self.delegateMap.objectEnumerator.allObjects) {
        if ([client respondsToSelector:aSelector]) {
            Class cls = object_getClass(client);
            Method method = class_getInstanceMethod(cls, aSelector);
            const char* typeEncoding = method_getTypeEncoding(method);
            
            return [NSMethodSignature signatureWithObjCTypes:typeEncoding];
        }
    }
    
    return [super methodSignatureForSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    for (id client in self.delegateMap.objectEnumerator.allObjects) {
        if ([client respondsToSelector:anInvocation.selector] &&
            ![self.delegateDisableDic containsObject:client]) {
            anInvocation.target = client;
            [anInvocation invoke];
        }
    }
}

#pragma mark - Private

- (BOOL)didConfigHost:(id)host withProtocol:(Protocol *)protocol {
    for (NSString *object in self.protocolToDelegateMap.objectEnumerator.allObjects) {
        NSArray *objectArray = [object componentsSeparatedByString:kDDSeparatedString];
        NSString *hostString = objectArray.firstObject;
        NSString *protocolName = objectArray.lastObject;
        if ([hostString isEqualToString:[NSString stringWithFormat:@"%p", host]] &&
            [protocolName isEqualToString:[NSString stringWithUTF8String:protocol_getName(protocol)]]) {
            return YES;
        }
    }
    
    return NO;
}

- (NSString *)delegateKeyForHost:(id)host protocol:(Protocol *)protocol client:(id)client {
    return [NSString stringWithFormat:@"%p%@%s%@%p", host, kDDSeparatedString, protocol_getName(protocol), kDDSeparatedString, client];
}

- (NSString *)protocolToDelegateKeyForHost:(id)host selector:(SEL)selector {
    return [NSString stringWithFormat:@"%p%@%s", host, kDDSeparatedString, sel_getName(selector)];
}

- (NSString *)protocolToDelegateObjectForHost:(id)host protocol:(Protocol *)protocol {
    return [NSString stringWithFormat:@"%p%@%s", host, kDDSeparatedString, protocol_getName(protocol)];
}

static void xb_setDelegate(__unsafe_unretained id assignSlf, SEL selector, id delegate) {
    NSString *key = [[DelegateDispatch shareInstance] protocolToDelegateKeyForHost:assignSlf selector:selector];
    NSString *value = [[DelegateDispatch shareInstance].protocolToDelegateMap objectForKey:key];
    NSString *protocolName = [value componentsSeparatedByString:kDDSeparatedString].lastObject;
    Protocol *protocol  = objc_getProtocol(protocolName.UTF8String);
    
    if (protocol && ![delegate isKindOfClass:[DelegateDispatch class]]) {
        [[DelegateDispatch shareInstance] addDelegateWithHost:assignSlf protocol:protocol client:delegate];
    }
}

#pragma mark - Getter

- (NSMapTable *)delegateMap {
    if (!_delegateMap) {
        _delegateMap = [NSMapTable mapTableWithKeyOptions:NSMapTableCopyIn valueOptions:NSMapTableWeakMemory | NSMapTableObjectPointerPersonality];
    }
    
    return _delegateMap;
}

- (NSMapTable *)protocolToDelegateMap {
    if (!_protocolToDelegateMap) {
        _protocolToDelegateMap = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableStrongMemory | NSMapTableObjectPointerPersonality];
    }
    
    return _protocolToDelegateMap;
}

- (NSHashTable *)delegateDisableDic {
    if (!_delegateDisableDic) {
        _delegateDisableDic = [NSHashTable hashTableWithOptions:NSHashTableWeakMemory | NSHashTableObjectPointerPersonality];
    }
    
    return _delegateDisableDic;
}

@end

