//
//  WeexCacheManager.h
//  blife-ios
//
//  Created by 胡广宇 on 2018/4/25.
//  Copyright © 2018年 www.witgo.cn. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void (^WeexCacheUrlBlock)(NSURL *renderUrl);

@interface WeexCacheManager : NSObject

/**
 单例对象
 
 @return 单例对象
 */
+ (instancetype)defaultManager;

/**
 获取实际加载的JS路径URL
 
 @param requestUrl 回调
 @param callBack 回调
 */
- (void)getRenderUrlWithRequestUrl:(NSString *)requestUrl callBack:(WeexCacheUrlBlock)callBack;

/**
 清除WeexJS缓存
 */
- (void)clearWeexJsCache;

/**
 获取WeexJs缓存大小
 */
- (long long)getWeexJsCacheSize;

@end
