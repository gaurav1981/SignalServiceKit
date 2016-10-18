//  Created by Michael Kirk on 10/7/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

#import "OWSMessageSender.h"
#import "OWSError.h"
#import "OWSUploadingService.h"
#import "TSAttachmentStream.h"
#import "TSMessagesManager+sendMessages.h"
#import "TSNetworkManager.h"
#import "TSOutgoingMessage.h"
#import "TSThread.h"

NS_ASSUME_NONNULL_BEGIN

@interface OWSMessageSender ()

@property (nonatomic, readonly) TSNetworkManager *networkManager;
@property (nonatomic, readonly) TSMessagesManager *messagesManager;
@property (nonatomic, readonly) OWSUploadingService *uploadingService;

@end

@implementation OWSMessageSender

- (instancetype)initWithNetworkManager:(TSNetworkManager *)networkManager
                        storageManager:(TSStorageManager *)storageManager
                       contactsManager:(id<ContactsManagerProtocol>)contactsManager
                       contactsUpdater:(ContactsUpdater *)contactsUpdater
{
    self = [super init];
    if (!self) {
        return self;
    }

    _networkManager = networkManager;
    _uploadingService = [[OWSUploadingService alloc] initWithNetworkManager:networkManager];

    _messagesManager = [[TSMessagesManager alloc] initWithNetworkManager:networkManager
                                                          storageManager:storageManager
                                                         contactsManager:contactsManager
                                                         contactsUpdater:contactsUpdater
                                                           messageSender:self];

    return self;
}

- (void)sendMessage:(TSOutgoingMessage *)message
            success:(void (^)())successHandler
            failure:(void (^)(NSError *error))failureHandler
{
    [self ensureAnyAttachmentsUploaded:message
                               success:^() {
                                   [self.messagesManager
                                       sendMessage:message
                                          inThread:message.thread
                                           success:successHandler
                                           failure:^{
                                               NSString *localizedError = NSLocalizedString(@"NOTIFICATION_SEND_FAILED",
                                                   @"Generic notice when message failed to send.");
                                               NSError *error = OWSErrorWithCodeDescription(
                                                   OWSErrorCodeFailedToSendOutgoingMessage, localizedError);
                                               failureHandler(error);
                                           }];
                               }
                               failure:failureHandler];
}

- (void)ensureAnyAttachmentsUploaded:(TSOutgoingMessage *)message
                             success:(void (^)())successHandler
                             failure:(void (^)(NSError *error))failureHandler
{
    if (!message.hasAttachments) {
        DDLogDebug(@"%@ No attachments for message: %@", self.tag, message);
        successHandler();
        return;
    }

    TSAttachmentStream *attachmentStream =
        [TSAttachmentStream fetchObjectWithUniqueID:message.attachmentIds.firstObject];
    if (!attachmentStream) {
        DDLogError(@"%@ Unable to find local saved attachment to upload.", self.tag);
        NSString *localizedError
            = NSLocalizedString(@"NOTIFICATION_SEND_FAILED", @"Generic notice when message failed to send.");
        NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeFailedToSendOutgoingMessage, localizedError);
        failureHandler(error);
        return;
    }

    [self.uploadingService uploadData:attachmentStream.readDataFromFile
                          contentType:attachmentStream.contentType
                              message:message
                              success:successHandler
                              failure:failureHandler];
}

- (void)sendTemporaryAttachmentData:(NSData *)attachmentData
                        contentType:(NSString *)contentType
                          inMessage:(TSOutgoingMessage *)message
                            success:(void (^)())successHandler
                            failure:(void (^)(NSError *error))failureHandler
{
    void (^successWithDeleteHandler)() = ^() {
        if (successHandler) {
            successHandler();
        }
        DDLogDebug(@"Removing temporary attachment message.");
        [message remove];
    };

    void (^failureWithDeleteHandler)(NSError *error) = ^(NSError *error) {
        if (failureHandler) {
            failureHandler(error);
        }
        DDLogDebug(@"Removing temporary attachment message.");
        [message remove];
    };

    [self sendAttachmentData:attachmentData
                 contentType:contentType
                   inMessage:message
                     success:successWithDeleteHandler
                     failure:failureWithDeleteHandler];
}

- (void)sendAttachmentData:(NSData *)data
               contentType:(NSString *)contentType
                 inMessage:(TSOutgoingMessage *)message
                   success:(void (^)())successHandler
                   failure:(void (^)(NSError *error))failureHandler
{
    // TODO background queue since this writes to disk, or move whole method call to queue.
    TSAttachmentStream *attachmentStream = [[TSAttachmentStream alloc] initWithData:data contentType:contentType];
    [attachmentStream save];
    [message.attachmentIds addObject:attachmentStream.uniqueId];

    message.messageState = TSOutgoingMessageStateAttemptingOut;
    [message save];

    [self sendMessage:message success:successHandler failure:failureHandler];
}


#pragma mark - Logging

+ (NSString *)tag
{
    return [NSString stringWithFormat:@"[%@]", self.class];
}

- (NSString *)tag
{
    return self.class.tag;
}

@end

NS_ASSUME_NONNULL_END
