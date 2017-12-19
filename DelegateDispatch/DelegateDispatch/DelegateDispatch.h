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

- (void)addDelegateWithHost:(id)host protocol:(Protocol *)protocol client:(id)client;

- (void)setDelegateEnable:(BOOL)enable forClient:(id)client;

@end

