//  Created by Michael Kirk on 10/7/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

NS_ASSUME_NONNULL_BEGIN

@class TSOutgoingMessage;
@class TSNetworkManager;
@class TSStorageManager;
@class ContactsUpdater;
@class TSMessagesManager;
@protocol ContactsManagerProtocol;

@interface OWSMessageSender : NSObject {

@protected
    // For subclassing in tests
    TSMessagesManager *_messagesManager;
}

- (instancetype)initWithNetworkManager:(TSNetworkManager *)networkManager
                        storageManager:(TSStorageManager *)storageManager
                       contactsManager:(id<ContactsManagerProtocol>)contactsManager
                       contactsUpdater:(ContactsUpdater *)contactsUpdater;

/**
 * Send and resend text messages or resend messages with existing attachments.
 * If you haven't yet created the attachment, see the `sendAttachmentData:` variants.
 */
- (void)sendMessage:(TSOutgoingMessage *)message
            success:(void (^)())successHandler
            failure:(void (^)(NSError *error))failureHandler;

/**
 * Takes care of allocating and uploading the attachment, then sends the message.
 * Only necessary to call once. If sending fails, retry with `sendMessage:`.
 */
- (void)sendAttachmentData:(NSData *)attachmentData
               contentType:(NSString *)contentType
                 inMessage:(TSOutgoingMessage *)outgoingMessage
                   success:(void (^)())successHandler
                   failure:(void (^)(NSError *error))failureHandler;
/**
 * Same as `sendAttachmentData:`, but deletes the local copy of the attachment after sending.
 * Used for sending sync request data, not for user visible attachments.
 */
- (void)sendTemporaryAttachmentData:(NSData *)attachmentData
                        contentType:(NSString *)contentType
                          inMessage:(TSOutgoingMessage *)outgoingMessage
                            success:(void (^)())successHandler
                            failure:(void (^)(NSError *error))failureHandler;

@end

NS_ASSUME_NONNULL_END
