//
//  WeexCacheManager.m
//
//  Created by 胡广宇 on 2018/4/25.
//  Copyright © 2018年 www.witgo.cn. All rights reserved.
//

#import "WeexCacheManager.h"
#import <AFNetworking/AFNetworking.h>
#import <CommonCrypto/CommonDigest.h>

/*---------------------- 文件操作类 ----------------------*/

@interface FileUnit : NSObject

/**
 获取Cache路径
 */
+ (NSString *)getCachePath;

/**
 创建文件路径
 */
+ (BOOL)creatDirectoryWithPath:(NSString *)dirPath;

/**
 判断文件是否存在于某个路径中
 */
+ (BOOL)fileIsExistOfPath:(NSString *)filePath;

/**
 从某个路径中移除文件
 */
+ (BOOL)removeFileOfPath:(NSString *)filePath;

/**
 获取文件大小
 */
+ (long long)getFileSizeWithPath:(NSString *)path;

@end

@implementation FileUnit

+ (NSString *)getCachePath
{
    NSArray *filePaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [filePaths objectAtIndex:0];
}

+ (BOOL)creatDirectoryWithPath:(NSString *)dirPath
{
    BOOL ret = YES;
    BOOL isExist = [[NSFileManager defaultManager] fileExistsAtPath:dirPath];
    if (!isExist) {
        NSError *error;
        BOOL isSuccess = [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&error];
        if (!isSuccess) {
            ret = NO;
            NSLog(@"creat Directory Failed. errorInfo:%@",error);
        }
    }
    return ret;
}

+ (BOOL)fileIsExistOfPath:(NSString *)filePath
{
    BOOL flag = NO;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:filePath]) {
        flag = YES;
    } else {
        flag = NO;
    }
    return flag;
}


+ (BOOL)removeFileOfPath:(NSString *)filePath
{
    BOOL flag = YES;
    NSFileManager *fileManage = [NSFileManager defaultManager];
    if ([fileManage fileExistsAtPath:filePath]) {
        if (![fileManage removeItemAtPath:filePath error:nil]) {
            flag = NO;
        }
    }
    return flag;
}

+ (long long)getFileSizeWithPath:(NSString *)path
{
    unsigned long long fileLength = 0;
    NSNumber *fileSize;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:path error:nil];
    if ((fileSize = [fileAttributes objectForKey:NSFileSize])) {
        fileLength = [fileSize unsignedLongLongValue];
    }
    return fileLength;
}

@end

/*---------------------- 缓存管理类 ----------------------*/

NSInteger const UpdateTime = 0.5 * 60 * 60; // 更新时间, 若在此时间内则不需要更新

NSString *const CacheHost = @"CacheHost";

NSString *const Timestamp = @"Timestamp";

NSString *const ETag = @"ETag";

@interface WeexCacheManager ()

/** URL回调 */
@property (nonatomic, copy) WeexCacheUrlBlock callBack;
/** 本地JS文件存储路径 */
@property (nonatomic, copy) NSString *localLibrary;
/** plist文件路径 */
@property (nonatomic, copy) NSString *cachePlistPath;
/** 本地Plist文件存储JS文件对应的ETag/时间戳/域名等参数 判断是否更新缓存JS */
@property (nonatomic, strong) NSMutableDictionary *cachePlist;

@end

@implementation WeexCacheManager

/**
 单例对象
 
 @return 单例对象
 */
+ (instancetype)defaultManager
{
    static WeexCacheManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
        // 初始化本地JS存储的路径, 读取Plist文件
        [manager initLibrary];
    });
    return manager;
}


/**
 回调并置空

 @param URL URL
 */
- (void)callBackURL:(NSURL *)URL {
    if (self.callBack) {
        self.callBack(URL);
        self.callBack = nil;
    }
}

/**
 获取实际加载的JS路径URL
 
 @param requestUrl 回调
 @param callBack 回调
 */
- (void)getRenderUrlWithRequestUrl:(NSString *)requestUrl callBack:(WeexCacheUrlBlock)callBack {
    // 保存回调方法
    self.callBack = callBack;
    // 每次加载新的URL都需要重新读取Plist,保证加载最新的URL时本地Plist文件内容为最新
    _cachePlist = nil;
    // 转URL类用于方便去URL中对应的字段
    NSURL *URL = [NSURL URLWithString:requestUrl];
    //找到文件名 比如home.js或者home.html
    NSString *fileName = [[[URL relativePath] componentsSeparatedByString:@"/"] lastObject];
    if ([fileName rangeOfString:@".html"].location != NSNotFound) {
        // 降级的HTML地址 无需考虑缓存
        [self callBackURL:URL];
        return;
    }
    // 文件路径的MD5值, 用于判断本地是否存在该文件
    NSString *md5Key = [self md5To32bit:[NSString stringWithFormat:@"%@://%@%@", URL.scheme, URL.host, [[URL.relativePath componentsSeparatedByString:@"."] firstObject]]];
    // 判断是否存在缓存JS文件
    if ([FileUnit fileIsExistOfPath:[NSString stringWithFormat:@"%@%@.js", self.localLibrary, md5Key]]) {\
        // 验证时间戳和ETag值
        [self verifyUpdateDateWithJsUrl:requestUrl md5Key:md5Key];
        return;
    }
    // 下载并缓存并加载JS
    [self downloadJsFile:URL md5Key:md5Key];
}

- (void)verifyUpdateDateWithJsUrl:(NSString *)jsUrl md5Key:(NSString *)md5Key {
    // 转URL类用于方便去URL中对应的字段
    NSURL *URL = [NSURL URLWithString:jsUrl];
    // 本地文件名称
    NSString *jsCachePath = [NSString stringWithFormat:@"%@%@.js", self.localLibrary, md5Key];
    // 上次验证的ETag 用于服务端是否更新文件
    NSString *oldETag = self.cachePlist[md5Key][ETag];
    // 上次验证的ETag时间
    NSString *oldTimestamp = self.cachePlist[md5Key][Timestamp];
    if (oldETag && oldTimestamp) {
        // 先判断时间是否在更新时间内
        if (([[NSDate date] timeIntervalSince1970] - [oldTimestamp floatValue]) > UpdateTime) {
            // 超过时间 判断ETag是否一致
            [[AFHTTPSessionManager manager] HEAD:jsUrl parameters:nil success:^(NSURLSessionDataTask * _Nonnull task) {
                NSString *eTag = [self getETagStringWithResponse:task.response];
                if ([oldETag isEqualToString:eTag]) {
                    // ETag一样说明服务端未更新, 修改文件的时间标识为最新时间, 加载缓存JS
                    NSMutableDictionary *cacheJsDic = [NSMutableDictionary dictionaryWithDictionary:self.cachePlist[md5Key]];
                    [cacheJsDic setValue:[NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]] forKey:@"Timestamp"];
                    [self.cachePlist setValue:cacheJsDic forKey:md5Key];
                    // 加载缓存JS文件
                    [self callBackURL:[self getJsCacheURL:jsCachePath originalURL:URL md5Key:md5Key]];
                } else {
                    // 服务端更新了, 删除本地JS, 并下载最新JS
                    [FileUnit removeFileOfPath:jsCachePath];
                    // 移除Plist中对应项
                    [self.cachePlist setValue:nil forKey:md5Key];
                    // 保存Plist文件
                    [self saveCachePlist];
                    // 下载最新JS
                    [self downloadJsFile:URL md5Key:md5Key];
                }
                [self saveCachePlist];
            } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
                // 请求失败, 可能无网络 加载缓存JS
                [self callBackURL:[self getJsCacheURL:jsCachePath originalURL:URL md5Key:md5Key]];
            }];
        } else {
            // 更新时间内, 直接加载缓存JS
            [self callBackURL:[self getJsCacheURL:jsCachePath originalURL:URL md5Key:md5Key]];
        }
        return;
    }
    // 缺少判断参数 估计是文件存储错误 删除从新下载
    [FileUnit removeFileOfPath:jsCachePath];
    // 移除Plist中对应项
    [self.cachePlist setValue:nil forKey:md5Key];
    // 保存Plist文件
    [self saveCachePlist];
    // 下载并加载本地JS
    [self downloadJsFile:URL md5Key:md5Key];
}


/**
 获取完整的本地JS缓存文件
 */
- (NSURL *)getJsCacheURL:(NSString *)jsCachePath originalURL:(NSURL *)originalURL md5Key:(NSString *)md5Key {
    NSString *query = originalURL.query;
    if (query) {
        // query存在则将CacheHost拼接在后面
        query = [NSString stringWithFormat:@"%@&%@=%@", query, CacheHost, self.cachePlist[md5Key][CacheHost]];
    } else {
        // query不存在则将CacheHost存为参数
        query = [NSString stringWithFormat:@"%@=%@", CacheHost, self.cachePlist[md5Key][CacheHost]];
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"file://%@?%@", jsCachePath, query]];
}

/**
 下载并加载已缓存的本地JS文件

 @param requestURL 原JS请求地址
 */
- (void)downloadJsFile:(NSURL *)requestURL md5Key:(NSString *)md5Key {
    // 下载前判断文件是否存在 (针对使用过程清楚缓存导致文件夹不存在)
    [FileUnit creatDirectoryWithPath:self.localLibrary];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        // 下载路径+文件名称
        NSString *downloadPath = [NSString stringWithFormat:@"%@%@.js", self.localLibrary, md5Key];
        NSURLSessionDownloadTask *task = [[AFHTTPSessionManager manager] downloadTaskWithRequest:[NSURLRequest requestWithURL:requestURL] progress:nil destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
            return [NSURL fileURLWithPath:downloadPath];
        } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
            if (!error) {
                NSLog(@"JS文件缓存成功!地址:%@", filePath);
                // 获取Etag值
                NSString *eTag = [self getETagStringWithResponse:response];
                NSMutableDictionary *jsDic = [NSMutableDictionary dictionary];
                // 存储文件相对路径, 用于查看文件真实名称
                [jsDic setValue:[requestURL relativePath] forKey:@"RelativePath"];
                // 存储Etag值
                [jsDic setValue:eTag forKey:ETag];
                [jsDic setValue:[NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]] forKey:Timestamp];
                // 存储可能变化的域名, 用于js中请求网络和图片资源
                [jsDic setValue:[self URLEncodedString:[NSString stringWithFormat:@"%@://%@", requestURL.scheme, requestURL.host]] forKey:CacheHost];
                // 存储该文件的额外字段
                [self.cachePlist setValue:jsDic forKey:md5Key];
                // 保存Plist
                [self saveCachePlist];
                // 加载缓存的JS
                [self callBackURL:[self getJsCacheURL:downloadPath originalURL:requestURL md5Key:md5Key]];
            } else {
                NSLog(@"JS文件缓存失败:%@", [error description]);
                // 加载出错直接加载URL
                [self callBackURL:requestURL];
            }
        }];
        [task resume];
    });
}


/**
 获取请求的ETag值(表示服务端JS文件是否更新)

 @param response 请求回调
 @return ETag
 */
- (NSString *)getETagStringWithResponse:(NSURLResponse *)response {
    // 找到请求回调中的Headers
    NSDictionary *headers = [response valueForKey:@"allHeaderFields"];
    if (headers && [headers valueForKey:@"ETag"]) {
        // 找到其中的ETag
        return [headers valueForKey:@"ETag"] ? [headers valueForKey:@"ETag"] : @"NoETag";
    }
    return @"NoETag";
}

/**
 初始化缓存文件
 */
- (void)initLibrary {
    // 获取APP的Cache目录
    self.localLibrary = [NSString stringWithFormat:@"%@/WeexBoundle/", [FileUnit getCachePath]];
    // 获取标识对应JS其他参数的Plist文件目录
    self.cachePlistPath = [NSString stringWithFormat:@"%@Cache.plist", self.localLibrary];
    // 没有缓存JS的目录就创建该目录
    [FileUnit creatDirectoryWithPath:self.localLibrary];
}

/**
 保存Plist文件
 */
- (void)saveCachePlist {
    [self.cachePlist writeToFile:self.cachePlistPath atomically:YES];
}

/**
 MD5加密(英文小写)
 */
- (NSString *)md5To32bit:(NSString *)originalString{
    const char *cStr = [originalString UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5( cStr, (unsigned int)strlen(cStr),digest );
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        [result appendFormat:@"%02x", digest[i]];
    return result;
}


/**
 *  URLEncode
 */
- (NSString *)URLEncodedString:(NSString *)originalString {
    NSMutableString *output = [NSMutableString string];
    const unsigned char *source = (const unsigned char *)[originalString UTF8String];
    long long int sourceLen = strlen((const char *)source);
    for (int i = 0; i < sourceLen; ++i) {
        const unsigned char thisChar = source[i];
        if (thisChar == ' '){
            [output appendString:@"+"];
        } else if (thisChar == '.' || thisChar == '-' || thisChar == '_' || thisChar == '~' ||
                   (thisChar >= 'a' && thisChar <= 'z') ||
                   (thisChar >= 'A' && thisChar <= 'Z') ||
                   (thisChar >= '0' && thisChar <= '9')) {
            [output appendFormat:@"%c", thisChar];
        } else {
            [output appendFormat:@"%%%02X", thisChar];
        }
    }
    return output;
}

/**
 清除WeexJS缓存
 */
- (void)clearWeexJsCache {
    [FileUnit removeFileOfPath:self.localLibrary];
}

/**
 获取WeexJs缓存大小
 */
- (long long)getWeexJsCacheSize {
    return [FileUnit getFileSizeWithPath:self.localLibrary];
}


/**
 懒加载, 获取本地Plist文件内容

 @return 字典Map
 */
- (NSDictionary *)cachePlist {
    if (!_cachePlist) {
        if ([FileUnit fileIsExistOfPath:self.cachePlistPath]) {
            // 存在该文件则读取Plist文件
            _cachePlist = [NSMutableDictionary dictionaryWithContentsOfFile:self.cachePlistPath];
        } else {
            // 不存在创建Plist文件
            _cachePlist = [[NSMutableDictionary alloc] init];
            [_cachePlist writeToFile:self.cachePlistPath atomically:YES];
        }
    }
    return _cachePlist;
}

@end
