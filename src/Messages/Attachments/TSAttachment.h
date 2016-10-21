//  Created by Frederic Jacobs on 12/11/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.

#import "TSYapDatabaseObject.h"

NS_ASSUME_NONNULL_BEGIN

@interface TSAttachment : TSYapDatabaseObject

@property (nonatomic) UInt64 serverId;
@property (atomic) NSData *encryptionKey;
@property (nonatomic) NSString *contentType;

- (instancetype)initWithServerId:(UInt64)serverId
                   encryptionKey:(NSData *)encryptionKey
                     contentType:(NSString *)contentType;

@end

NS_ASSUME_NONNULL_END
