//
//  DelegateDispatch.h
//  DelegateDispatch
//
//  Created by xiabob on 2017/12/19.
//  Copyright © 2017年 xiabob. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface DelegateDispatch : NSObject

+ (instancetype)shareInstance;

- (void)configDelegateDispatchWithHost:(id)host protocol:(Protocol *)protocol delegateSetter:(SEL)selector delegateObject:(id)delegate;

- (void)addDelegateClient:(id)client forHost:(id)host withProtocol:(Protocol *)protocol;

- (void)removeDelegateClient:(id)client forHost:(id)host withProtocol:(Protocol *)protocol;
- (void)removeAllDelegateClients:(id)client forHost:(id)host withProtocol:(Protocol *)protocol;

@end

