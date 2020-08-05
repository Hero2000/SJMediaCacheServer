//
//  MCSResource.m
//  SJMediaCacheServer_Example
//
//  Created by 畅三江 on 2020/6/2.
//  Copyright © 2020 changsanjiang@gmail.com. All rights reserved.
//

#import "MCSVODResource.h"
#import "MCSResourceDefines.h"
#import "MCSVODReader.h"
#import "MCSResourceManager.h"
#import "MCSFileManager.h"
#import "MCSUtils.h"
#import "MCSResourceSubclass.h"
#import "MCSQueue.h"

@interface MCSVODResource () {
    NSURL *_playbackURLForCache;
}
@property (nonatomic, copy, nullable) NSString *contentType;
@property (nonatomic, copy, nullable) NSString *server;
@property (nonatomic) NSUInteger totalLength;
@property (nonatomic, copy, nullable) NSString *pathExtension;
@end

@implementation MCSVODResource

- (MCSResourceType)type {
    return MCSResourceTypeVOD;
}

- (id<MCSResourceReader>)readerWithRequest:(NSURLRequest *)request {
    return [MCSVODReader.alloc initWithResource:self request:request];
}

- (NSURL *)playbackURLForCacheWithURL:(NSURL *)URL {
    __block NSURL *playbackURLForCache = nil;
    dispatch_sync(MCSResourceQueue(), ^{
        playbackURLForCache = _playbackURLForCache;
    });
    return playbackURLForCache;
}

- (void)prepareForReader {
    [self addContents:[MCSFileManager getContentsInResource:_name]];
}

- (nullable MCSResourcePartialContent *)createContentWithRequest:(NSURLRequest *)request response:(NSHTTPURLResponse *)response {
    __block BOOL isUpdated = NO;
    dispatch_barrier_sync(MCSResourceQueue(), ^{
        if ( _server == nil || _contentType == nil || _totalLength == 0 || _pathExtension == nil ) {
            _contentType = MCSGetResponseContentType(response);
            _server = MCSGetResponseServer(response);
            _totalLength = MCSGetResponseContentRange(response).totalLength;
            _pathExtension = MCSSuggestedFilePathExtension(response);
            isUpdated = YES;
        }
    });
    if ( isUpdated ) [MCSResourceManager.shared saveMetadata:self];
    NSUInteger offset = request.mcs_range.location;
    NSString *filename = [MCSFileManager vod_createContentFileInResource:self.name atOffset:offset pathExtension:self.pathExtension];
    MCSResourcePartialContent *content = [MCSResourcePartialContent.alloc initWithFilename:filename offset:offset];
    [self addContent:content];
    return content;
}

#pragma mark -

- (NSUInteger)totalLength {
    __block NSUInteger totalLength = 0;
    dispatch_sync(MCSResourceQueue(), ^{
        totalLength = _totalLength;
    });
    return totalLength;
}
 
- (NSString *)contentType {
    __block NSString *contentType = nil;
    dispatch_sync(MCSResourceQueue(), ^{
        contentType = _contentType;
    });
    return contentType;
}
 
- (NSString *)server {
    __block NSString *server = nil;
    dispatch_sync(MCSResourceQueue(), ^{
        server = _server;
    });
    return server;
}

#pragma mark -

- (void)readWriteCountDidChangeForPartialContent:(MCSResourcePartialContent *)content {
    if ( content.readWriteCount > 0 )
        return;

    dispatch_barrier_sync(MCSResourceQueue(), ^{
        if ( _isCacheFinished )
            return;
        
        if ( _m.count <= 1 )
            return;
        
        // 合并文件
        NSMutableArray<MCSResourcePartialContent *> *list = NSMutableArray.alloc.init;
        for ( MCSResourcePartialContent *content in _m ) {
            if ( content.readWriteCount == 0 )
                [list addObject:content];
        }
        
        NSMutableArray<MCSResourcePartialContent *> *deleteContents = NSMutableArray.alloc.init;
        [list sortUsingComparator:^NSComparisonResult(MCSResourcePartialContent *obj1, MCSResourcePartialContent *obj2) {
            NSRange range1 = NSMakeRange(obj1.offset, obj1.length);
            NSRange range2 = NSMakeRange(obj2.offset, obj2.length);
            
            // 1 包含 2
            if ( MCSNSRangeContains(range1, range2) ) {
                if ( ![deleteContents containsObject:obj2] ) [deleteContents addObject:obj2];
            }
            // 2 包含 1
            else if ( MCSNSRangeContains(range2, range1) ) {
                if ( ![deleteContents containsObject:obj1] ) [deleteContents addObject:obj1];;
            }
            
            return range1.location < range2.location ? NSOrderedAscending : NSOrderedDescending;
        }];
        
        if ( deleteContents.count != 0 ) [list removeObjectsInArray:deleteContents];
        
        for ( NSInteger i = 0 ; i < list.count - 1; i += 2 ) {
            MCSResourcePartialContent *write = list[i];
            MCSResourcePartialContent *read  = list[i + 1];
            NSRange readRange = NSMakeRange(0, 0);
            
            NSUInteger maxA = write.offset + write.length;
            NSUInteger maxR = read.offset + read.length;
            if ( maxA >= read.offset && maxA < maxR ) // 有交集
                readRange = NSMakeRange(maxA - read.offset, maxR - maxA); // 读取read中未相交的部分
            
            if ( readRange.length != 0 ) {
                NSFileHandle *writer = [NSFileHandle fileHandleForWritingAtPath:[self filePathOfContent:write]];
                NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:[self filePathOfContent:read]];
                @try {
                    [writer seekToEndOfFile];
                    [reader seekToFileOffset:readRange.location];
                    while (true) {
                        @autoreleasepool {
                            NSData *data = [reader readDataOfLength:1024 * 1024 * 1];
                            if ( data.length == 0 )
                                break;
                            [writer writeData:data];
                        }
                    }
                    [reader closeFile];
                    [writer synchronizeFile];
                    [writer closeFile];
                    [write didWriteDataWithLength:readRange.length];
                    [deleteContents addObject:read];
                } @catch (NSException *exception) {
                    break;
                }
            }
        }
        
        for ( MCSResourcePartialContent *content in deleteContents ) {
            [self removeContent:content];
        }
    });
}

- (void)contentsDidChange:(NSArray<MCSResourcePartialContent *> *)contents {
    if ( _isCacheFinished )
        return;
    if ( _totalLength == 0 )
        return;
    if ( contents.count > 1 )
        return;
    
    MCSResourcePartialContent *result = contents.lastObject;
    _isCacheFinished = result.length == _totalLength;
    if ( _isCacheFinished ) {
        NSString *resultPath = [self filePathOfContent:result];
        _playbackURLForCache = [NSURL fileURLWithPath:resultPath];
    }
}
@end
