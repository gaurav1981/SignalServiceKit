//  Created by Frederic Jacobs on 17/12/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.

#import "TSAttachment.h"
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface TSAttachmentStream : TSAttachment

- (instancetype)initWithData:(NSData *)data contentType:(NSString *)contentType NS_DESIGNATED_INITIALIZER;

// Override superclass to be readwrite
@property (nonatomic) NSUInteger serverId;
@property (nonatomic) BOOL isDownloaded;
@property (atomic) NSData *encryptionKey;

#if TARGET_OS_IPHONE
- (nullable UIImage *)image;
#endif

- (BOOL)isAnimated;
- (BOOL)isImage;
- (BOOL)isVideo;
- (nullable NSString *)filePath;
- (nullable NSURL *)mediaURL;

+ (void)deleteAttachments;
+ (NSString *)attachmentsFolder;
+ (NSUInteger)numberOfItemsInAttachmentsFolder;

@end

NS_ASSUME_NONNULL_END
