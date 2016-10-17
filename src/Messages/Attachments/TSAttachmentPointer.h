//  Created by Frederic Jacobs on 17/12/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.

#import "TSAttachment.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * A TSAttachmentPointer is a yet-to-be-downloaded attachment.
 */
@interface TSAttachmentPointer : TSAttachment

- (instancetype)initWithServerId:(NSUInteger)serverId
                             key:(NSData *)key
                     contentType:(NSString *)contentType
                           relay:(NSString *)relay NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithServerId:(NSUInteger)serverId
                             key:(NSData *)key
                     contentType:(NSString *)contentType
                           relay:(NSString *)relay
                 avatarOfGroupId:(NSData *)avatarOfGroupId;

@property (nonatomic, readonly) NSString *relay;
@property (nonatomic, readonly) NSData *avatarOfGroupId;

@property (getter=isDownloading) BOOL downloading;
@property (getter=hasFailed) BOOL failed;

@end

NS_ASSUME_NONNULL_END
