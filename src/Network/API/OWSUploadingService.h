//  Created by Michael Kirk on 10/18/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

NS_ASSUME_NONNULL_BEGIN

@class TSOutgoingMessage;
@class TSNetworkManager;

@interface OWSUploadingService : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithNetworkManager:(TSNetworkManager *)networkManager NS_DESIGNATED_INITIALIZER;

- (void)uploadData:(NSData *)data
       contentType:(NSString *)contentType
           message:(TSOutgoingMessage *)outgoingMessage
           success:(void (^)(TSOutgoingMessage *messageWithAttachment))successHandler
           failure:(void (^)(NSError *error))failureHandler;

@end

NS_ASSUME_NONNULL_END
