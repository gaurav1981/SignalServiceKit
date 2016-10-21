//  Created by Michael Kirk on 10/7/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

#import "OWSMessageSender.h"
#import "ContactsUpdater.h"
#import "NSData+messagePadding.h"
#import "OWSDisappearingMessagesJob.h"
#import "OWSDispatch.h"
#import "OWSError.h"
#import "OWSLegacyMessageServiceParams.h"
#import "OWSMessageServiceParams.h"
#import "OWSOutgoingSentMessageTranscript.h"
#import "OWSOutgoingSyncMessage.h"
#import "OWSUploadingService.h"
#import "PreKeyBundle+jsonDict.h"
#import "SignalRecipient.h"
#import "TSAccountManager.h"
#import "TSAttachmentStream.h"
#import "TSContactThread.h"
#import "TSGroupThread.h"
#import "TSIncomingMessage.h"
#import "TSInfoMessage.h"
#import "TSInvalidIdentityKeySendingErrorMessage.h"
#import "TSNetworkManager.h"
#import "TSOutgoingMessage.h"
#import "TSStorageManager+IdentityKeyStore.h"
#import "TSStorageManager+PreKeyStore.h"
#import "TSStorageManager+SignedPreKeyStore.h"
#import "TSStorageManager+keyingMaterial.h"
#import "TSStorageManager+sessionStore.h"
#import "TSStorageManager.h"
#import "TSThread.h"
#import <AxolotlKit/AxolotlExceptions.h>
#import <AxolotlKit/CipherMessage.h>
#import <AxolotlKit/PreKeyBundle.h>
#import <AxolotlKit/SessionBuilder.h>
#import <AxolotlKit/SessionCipher.h>
#import <TwistedOakCollapsingFutures/CollapsingFutures.h>

NS_ASSUME_NONNULL_BEGIN

int const OWSMessageSenderRetryAttempts = 3;

@interface OWSMessageSender ()

@property (nonatomic, readonly) TSNetworkManager *networkManager;
@property (nonatomic, readonly) TSStorageManager *storageManager;
@property (nonatomic, readonly) OWSUploadingService *uploadingService;
@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;
@property (nonatomic, readonly) id<ContactsManagerProtocol> contactsManager;
@property (nonatomic, readonly) ContactsUpdater *contactsUpdater;
@property (nonatomic, readonly) OWSDisappearingMessagesJob *disappearingMessagesJob;

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
    _storageManager = storageManager;
    _contactsManager = contactsManager;
    _contactsUpdater = contactsUpdater;

    _uploadingService = [[OWSUploadingService alloc] initWithNetworkManager:networkManager];
    _dbConnection = storageManager.newDatabaseConnection;
    _disappearingMessagesJob = [[OWSDisappearingMessagesJob alloc] initWithStorageManager:storageManager];

    return self;
}

- (void)sendMessage:(TSOutgoingMessage *)message
            success:(void (^)())successHandler
            failure:(void (^)(NSError *error))failureHandler
{
    void (^markAndFailureHandler)(NSError *error) = ^(NSError *error) {
        [self saveMessage:message withState:TSOutgoingMessageStateUnsent];
        failureHandler(error);
    };

    [self ensureAnyAttachmentsUploaded:message
                               success:^() {
                                   [self sendMessage:message
                                            inThread:message.thread
                                             success:successHandler
                                             failure:markAndFailureHandler];
                               }
                               failure:markAndFailureHandler];
}

- (void)ensureAnyAttachmentsUploaded:(TSOutgoingMessage *)message
                             success:(void (^)())successHandler
                             failure:(void (^)(NSError *error))failureHandler
{
    if (!message.hasAttachments) {
        DDLogDebug(@"%@ No attachments for message: %@", self.tag, message);
        return successHandler();
    }

    TSAttachmentStream *attachmentStream =
        [TSAttachmentStream fetchObjectWithUniqueID:message.attachmentIds.firstObject];

    if (!attachmentStream) {
        DDLogError(@"%@ Unable to find local saved attachment to upload.", self.tag);
        NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
        return failureHandler(error);
    }

    [self.uploadingService uploadAttachmentStream:attachmentStream
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
        successHandler();

        DDLogDebug(@"Removing temporary attachment message.");
        [message remove];
    };

    void (^failureWithDeleteHandler)(NSError *error) = ^(NSError *error) {
        failureHandler(error);

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
    dispatch_async([OWSDispatch attachmentsQueue], ^{
        TSAttachmentStream *attachmentStream = [[TSAttachmentStream alloc] initWithData:data contentType:contentType];
        [attachmentStream save];
        [message.attachmentIds addObject:attachmentStream.uniqueId];

        message.messageState = TSOutgoingMessageStateAttemptingOut;
        [message save];

        [self sendMessage:message success:successHandler failure:failureHandler];
    });
}

- (void)resendMessageFromKeyError:(TSInvalidIdentityKeySendingErrorMessage *)errorMessage
                          success:(void (^)())successHandler
                          failure:(void (^)(NSError *error))failureHandler
{
    TSOutgoingMessage *message = [TSOutgoingMessage fetchObjectWithUniqueID:errorMessage.messageId];

    // Here we remove the existing error message because sending a new message will either
    //  1.) succeed and create a new successful message in the thread or...
    //  2.) fail and create a new identical error message in the thread.
    [errorMessage remove];

    if ([errorMessage.thread isKindOfClass:[TSContactThread class]]) {
        return [self sendMessage:message success:successHandler failure:failureHandler];
    }

    // else it's a GroupThread
    dispatch_async([OWSDispatch sendingQueue], ^{

        // Avoid spamming entire group when resending failed message.
        SignalRecipient *failedRecipient = [SignalRecipient fetchObjectWithUniqueID:errorMessage.recipientId];

        // Normally marking as unsent is handled in sendMessage happy path, but beacuse we're skipping the common entry
        // point to message sending in order to send to a single recipient, we have to handle it ourselves.
        void (^markAndFailureHandler)(NSError *error) = ^(NSError *error) {
            [self saveMessage:message withState:TSOutgoingMessageStateUnsent];
            failureHandler(error);
        };

        [self groupSend:@[ failedRecipient ]
                Message:message
               inThread:errorMessage.thread
                success:successHandler
                failure:markAndFailureHandler];
    });
}

#pragma mark - Methods after this point were mostly cut/paste extracted from old TSMessagesManager+send.h
//  Created by Frederic Jacobs on 17/11/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.

#define InvalidDeviceException @"InvalidDeviceException"

- (void)getRecipients:(NSArray<NSString *> *)identifiers
              success:(void (^)(NSArray<SignalRecipient *> *))success
              failure:(void (^)(NSError *error))failure
{
    NSMutableArray<SignalRecipient *> *recipients = [NSMutableArray new];

    __block NSError *latestError;
    for (NSString *recipientId in identifiers) {
        SignalRecipient *recipient = [SignalRecipient recipientWithTextSecureIdentifier:recipientId];

        if (!recipient) {
            NSError *error;
            SignalRecipient *newRecipient = [self.contactsUpdater synchronousLookup:recipientId error:&error];
            if (newRecipient) {
                [recipients addObject:newRecipient];
            }

            if (error) {
                DDLogWarn(@"Not sending message to unknown recipient with error: %@", error);
                latestError = error;
            };
        } else {
            [recipients addObject:recipient];
        }
    }

    if (recipients > 0) {
        return success(recipients);
    }

    return failure(latestError);
}

- (void)sendMessage:(TSOutgoingMessage *)message
           inThread:(TSThread *)thread
            success:(void (^)())successHandler
            failure:(void (^)(NSError *error))failureHandler
{
    dispatch_async([OWSDispatch sendingQueue], ^{
        if ([thread isKindOfClass:[TSGroupThread class]]) {
            TSGroupThread *groupThread = (TSGroupThread *)thread;
            [self getRecipients:groupThread.groupModel.groupMemberIds
                        success:^(NSArray<SignalRecipient *> *recipients) {
                            [self groupSend:recipients
                                    Message:message
                                   inThread:thread
                                    success:successHandler
                                    failure:failureHandler];
                        }
                        failure:failureHandler];

        } else if ([thread isKindOfClass:[TSContactThread class]]
            || [message isKindOfClass:[OWSOutgoingSyncMessage class]]) {

            TSContactThread *contactThread = (TSContactThread *)thread;

            [self saveMessage:message withState:TSOutgoingMessageStateAttemptingOut];

            if ([contactThread.contactIdentifier isEqualToString:self.storageManager.localNumber]
                && ![message isKindOfClass:[OWSOutgoingSyncMessage class]]) {

                [self handleSendToMyself:message];
                return;
            }

            NSString *recipientContactId = [message isKindOfClass:[OWSOutgoingSyncMessage class]]
                ? self.storageManager.localNumber
                : contactThread.contactIdentifier;

            __block SignalRecipient *recipient = [SignalRecipient recipientWithTextSecureIdentifier:recipientContactId];
            if (!recipient) {

                NSError *error;
                // possibly returns nil.
                recipient = [self.contactsUpdater synchronousLookup:contactThread.contactIdentifier error:&error];

                if (error) {
                    if (error.code == NOTFOUND_ERROR) {
                        DDLogWarn(@"recipient contact not found with error: %@", error);
                        [self unregisteredRecipient:recipient message:message inThread:thread];
                    }
                    DDLogError(@"contact lookup failed with error: %@", error);
                    return failureHandler(error);
                }
            }

            if (!recipient) {
                NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
                DDLogWarn(@"recipient contact still not found after attempting lookup.");
                return failureHandler(error);
            }

            [self sendMessage:message
                  toRecipient:recipient
                     inThread:thread
                  withAttemps:OWSMessageSenderRetryAttempts
                      success:successHandler
                      failure:failureHandler];
        }
    });
}

/// For group sends, we're using chained futures to make the code more readable.

- (TOCFuture *)sendMessageFuture:(TSOutgoingMessage *)message
                       recipient:(SignalRecipient *)recipient
                        inThread:(TSThread *)thread
{
    TOCFutureSource *futureSource = [[TOCFutureSource alloc] init];

    [self sendMessage:message
        toRecipient:recipient
        inThread:thread
        withAttemps:OWSMessageSenderRetryAttempts
        success:^{
            [futureSource trySetResult:@1];
        }
        failure:^(NSError *error) {
            [futureSource trySetFailure:error];
        }];

    return futureSource.future;
}

- (void)groupSend:(NSArray<SignalRecipient *> *)recipients
          Message:(TSOutgoingMessage *)message
         inThread:(TSThread *)thread
          success:(void (^)())successHandler
          failure:(void (^)(NSError *error))failureHandler
{
    [self saveGroupMessage:message inThread:thread];
    NSMutableArray<TOCFuture *> *futures = [NSMutableArray array];

    for (SignalRecipient *rec in recipients) {
        // we don't need to send the message to ourselves, but otherwise we send
        if (![[rec uniqueId] isEqualToString:[TSStorageManager localNumber]]) {
            [futures addObject:[self sendMessageFuture:message recipient:rec inThread:thread]];
        }
    }

    TOCFuture *completionFuture = futures.toc_thenAll;

    [completionFuture thenDo:^(id value) {
        successHandler();
    }];

    [completionFuture catchDo:^(id failure) {
        NSError *error;
        if ([failure isKindOfClass:[NSError class]]) {
            error = (NSError *)failure;
        } else {
            error = OWSErrorMakeFailedToSendOutgoingMessageError();
        }
        failureHandler(error);
    }];
}

- (void)unregisteredRecipient:(SignalRecipient *)recipient
                      message:(TSOutgoingMessage *)message
                     inThread:(TSThread *)thread
{
    [self.dbConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [recipient removeWithTransaction:transaction];
        [[TSInfoMessage userNotRegisteredMessageInThread:thread transaction:transaction]
            saveWithTransaction:transaction];
    }];
}

- (void)sendMessage:(TSOutgoingMessage *)message
        toRecipient:(SignalRecipient *)recipient
           inThread:(TSThread *)thread
        withAttemps:(int)remainingAttempts
            success:(void (^)())successHandler
            failure:(void (^)(NSError *error))failureHandler
{
    if (remainingAttempts <= 0) {
        return failureHandler(OWSErrorMakeFailedToSendOutgoingMessageError());
    }
    remainingAttempts -= 1;

    NSArray<NSDictionary *> *deviceMessages;
    @try {
        deviceMessages = [self deviceMessages:message forRecipient:recipient inThread:thread];
    } @catch (NSException *exception) {
        deviceMessages = @[];
        if (remainingAttempts == 0) {
            DDLogWarn(
                @"%@ Terminal failure to build any device messages. Giving up with exception:%@", self.tag, exception);
            [self processException:exception outgoingMessage:message inThread:thread];
            NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
            failureHandler(error);
        }
    }

    TSSubmitMessageRequest *request = [[TSSubmitMessageRequest alloc] initWithRecipient:recipient.uniqueId
                                                                               messages:deviceMessages
                                                                                  relay:recipient.relay
                                                                              timeStamp:message.timestamp];

    [self.networkManager makeRequest:request
        success:^(NSURLSessionDataTask *task, id responseObject) {
            dispatch_async([OWSDispatch sendingQueue], ^{
                [recipient save];
                [self handleMessageSentLocally:message];
                successHandler();
            });
        }
        failure:^(NSURLSessionDataTask *task, NSError *error) {
            NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
            long statuscode = response.statusCode;
            NSData *responseData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];

            switch (statuscode) {
                case 404: {
                    // TODO move error handling into failureHandler
                    [self unregisteredRecipient:recipient message:message inThread:thread];
                    NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
                    return failureHandler(error);
                }
                case 409: {
                    // Mismatched devices
                    DDLogWarn(@"%@ Mismatch Devices.", self.tag);

                    NSError *e;
                    NSDictionary *serializedResponse =
                        [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&e];

                    if (e) {
                        DDLogError(@"%@ Failed to serialize response of mismatched devices: %@", self.tag, e);
                    } else {
                        [self handleMismatchedDevices:serializedResponse recipient:recipient];
                    }

                    dispatch_async([OWSDispatch sendingQueue], ^{
                        [self sendMessage:message
                              toRecipient:recipient
                                 inThread:thread
                              withAttemps:remainingAttempts
                                  success:successHandler
                                  failure:failureHandler];
                    });

                    break;
                }
                case 410: {
                    // staledevices
                    DDLogWarn(@"Stale devices");

                    if (!responseData) {
                        DDLogWarn(@"Stale devices but server didn't specify devices in response.");
                        NSError *error = OWSErrorMakeUnableToProcessServerResponseError();
                        return failureHandler(error);
                    }

                    [self handleStaleDevicesWithResponse:responseData recipientId:recipient.uniqueId];

                    dispatch_async([OWSDispatch sendingQueue], ^{
                        [self sendMessage:message
                              toRecipient:recipient
                                 inThread:thread
                              withAttemps:remainingAttempts
                                  success:successHandler
                                  failure:failureHandler];
                    });

                    break;
                }
                default:
                    [self sendMessage:message
                          toRecipient:recipient
                             inThread:thread
                          withAttemps:remainingAttempts
                              success:successHandler
                              failure:failureHandler];
                    break;
            }
        }];
}

- (void)handleMismatchedDevices:(NSDictionary *)dictionary recipient:(SignalRecipient *)recipient
{
    NSArray *extraDevices = [dictionary objectForKey:@"extraDevices"];
    NSArray *missingDevices = [dictionary objectForKey:@"missingDevices"];

    if (extraDevices && extraDevices.count > 0) {
        for (NSNumber *extraDeviceId in extraDevices) {
            [self.storageManager deleteSessionForContact:recipient.uniqueId deviceId:extraDeviceId.intValue];
        }

        [recipient removeDevices:[NSSet setWithArray:extraDevices]];
    }

    if (missingDevices && missingDevices.count > 0) {
        [recipient addDevices:[NSSet setWithArray:missingDevices]];
    }

    [recipient save];
}

- (void)handleMessageSentLocally:(TSOutgoingMessage *)message
{
    [self saveMessage:message withState:TSOutgoingMessageStateSent];
    if (message.shouldSyncTranscript) {
        message.hasSyncedTranscript = YES;
        [self sendSyncTranscriptForMessage:message];
    }

    [self.disappearingMessagesJob setExpirationForMessage:message];
}

- (void)handleMessageSentRemotely:(TSOutgoingMessage *)message sentAt:(uint64_t)sentAt
{
    [self saveMessage:message withState:TSOutgoingMessageStateDelivered];
    [self becomeConsistentWithDisappearingConfigurationForMessage:message];
    [self.disappearingMessagesJob setExpirationForMessage:message expirationStartedAt:sentAt];
}

- (void)becomeConsistentWithDisappearingConfigurationForMessage:(TSOutgoingMessage *)outgoingMessage
{
    [self.disappearingMessagesJob becomeConsistentWithConfigurationForMessage:outgoingMessage
                                                              contactsManager:self.contactsManager];
}

- (void)handleSendToMyself:(TSOutgoingMessage *)outgoingMessage
{
    [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        TSContactThread *cThread =
            [TSContactThread getOrCreateThreadWithContactId:[TSAccountManager localNumber] transaction:transaction];
        [cThread saveWithTransaction:transaction];
        TSIncomingMessage *incomingMessage =
            [[TSIncomingMessage alloc] initWithTimestamp:(outgoingMessage.timestamp + 1)
                                                inThread:cThread
                                                authorId:[cThread contactIdentifier]
                                             messageBody:outgoingMessage.body
                                           attachmentIds:outgoingMessage.attachmentIds
                                        expiresInSeconds:outgoingMessage.expiresInSeconds];
        [incomingMessage saveWithTransaction:transaction];
    }];
    [self handleMessageSentLocally:outgoingMessage];
}

- (void)sendSyncTranscriptForMessage:(TSOutgoingMessage *)message
{
    OWSOutgoingSentMessageTranscript *sentMessageTranscript =
        [[OWSOutgoingSentMessageTranscript alloc] initWithOutgoingMessage:message];

    [self sendMessage:sentMessageTranscript
        toRecipient:[SignalRecipient selfRecipient]
        inThread:message.thread
        withAttemps:OWSMessageSenderRetryAttempts
        success:^{
            DDLogInfo(@"Succesfully sent sync transcript.");
        }
        failure:^(NSError *error) {
            DDLogInfo(@"Failed to send sync transcript:%@", error);
        }];
}

- (NSArray<NSDictionary *> *)deviceMessages:(TSOutgoingMessage *)message
                               forRecipient:(SignalRecipient *)recipient
                                   inThread:(TSThread *)thread
{
    NSMutableArray *messagesArray = [NSMutableArray arrayWithCapacity:recipient.devices.count];
    NSData *plainText = [message buildPlainTextData];

    for (NSNumber *deviceNumber in recipient.devices) {
        @try {
            // DEPRECATED - Remove after all clients have been upgraded.
            BOOL isLegacyMessage = ![message isKindOfClass:[OWSOutgoingSyncMessage class]];

            NSDictionary *messageDict = [self encryptedMessageWithPlaintext:plainText
                                                                toRecipient:recipient.uniqueId
                                                                   deviceId:deviceNumber
                                                              keyingStorage:[TSStorageManager sharedManager]
                                                                     legacy:isLegacyMessage];
            if (messageDict) {
                [messagesArray addObject:messageDict];
            } else {
                @throw [NSException exceptionWithName:InvalidMessageException
                                               reason:@"Failed to encrypt message"
                                             userInfo:nil];
            }
        } @catch (NSException *exception) {
            if ([exception.name isEqualToString:InvalidDeviceException]) {
                [recipient removeDevices:[NSSet setWithObject:deviceNumber]];
            } else {
                @throw exception;
            }
        }
    }

    return [messagesArray copy];
}

- (NSDictionary *)encryptedMessageWithPlaintext:(NSData *)plainText
                                    toRecipient:(NSString *)identifier
                                       deviceId:(NSNumber *)deviceNumber
                                  keyingStorage:(TSStorageManager *)storage
                                         legacy:(BOOL)isLegacymessage
{
    if (![storage containsSession:identifier deviceId:[deviceNumber intValue]]) {
        __block dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block PreKeyBundle *bundle;

        [self.networkManager makeRequest:[[TSRecipientPrekeyRequest alloc] initWithRecipient:identifier
                                                                                    deviceId:[deviceNumber stringValue]]
            success:^(NSURLSessionDataTask *task, id responseObject) {
                bundle = [PreKeyBundle preKeyBundleFromDictionary:responseObject forDeviceNumber:deviceNumber];
                dispatch_semaphore_signal(sema);
            }
            failure:^(NSURLSessionDataTask *task, NSError *error) {
                DDLogError(@"Server replied on PreKeyBundle request with error: %@", error);
                NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
                if (response.statusCode == 404) {
                    @throw [NSException exceptionWithName:InvalidDeviceException
                                                   reason:@"Device not registered"
                                                 userInfo:nil];
                }
                dispatch_semaphore_signal(sema);
            }];
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

        if (!bundle) {
            @throw [NSException exceptionWithName:InvalidVersionException
                                           reason:@"Can't get a prekey bundle from the server with required information"
                                         userInfo:nil];
        } else {
            SessionBuilder *builder = [[SessionBuilder alloc] initWithSessionStore:storage
                                                                       preKeyStore:storage
                                                                 signedPreKeyStore:storage
                                                                  identityKeyStore:storage
                                                                       recipientId:identifier
                                                                          deviceId:[deviceNumber intValue]];
            @try {
                [builder processPrekeyBundle:bundle];
            } @catch (NSException *exception) {
                if ([exception.name isEqualToString:UntrustedIdentityKeyException]) {
                    @throw [NSException
                        exceptionWithName:UntrustedIdentityKeyException
                                   reason:nil
                                 userInfo:@{ TSInvalidPreKeyBundleKey : bundle, TSInvalidRecipientKey : identifier }];
                }
                @throw exception;
            }
        }
    }

    SessionCipher *cipher = [[SessionCipher alloc] initWithSessionStore:storage
                                                            preKeyStore:storage
                                                      signedPreKeyStore:storage
                                                       identityKeyStore:storage
                                                            recipientId:identifier
                                                               deviceId:[deviceNumber intValue]];

    id<CipherMessage> encryptedMessage = [cipher encryptMessage:[plainText paddedMessageBody]];
    NSData *serializedMessage = encryptedMessage.serialized;
    TSWhisperMessageType messageType = [self messageTypeForCipherMessage:encryptedMessage];

    OWSMessageServiceParams *messageParams;
    // DEPRECATED - Remove after all clients have been upgraded.
    if (isLegacymessage) {
        messageParams = [[OWSLegacyMessageServiceParams alloc] initWithType:messageType
                                                                recipientId:identifier
                                                                     device:[deviceNumber intValue]
                                                                       body:serializedMessage
                                                             registrationId:cipher.remoteRegistrationId];
    } else {
        messageParams = [[OWSMessageServiceParams alloc] initWithType:messageType
                                                          recipientId:identifier
                                                               device:[deviceNumber intValue]
                                                              content:serializedMessage
                                                       registrationId:cipher.remoteRegistrationId];
    }

    NSError *error;
    NSDictionary *jsonDict = [MTLJSONAdapter JSONDictionaryFromModel:messageParams error:&error];

    if (error) {
        DDLogError(@"Error while making JSON dictionary of message: %@", error.debugDescription);
        return nil;
    }

    return jsonDict;
}

- (TSWhisperMessageType)messageTypeForCipherMessage:(id<CipherMessage>)cipherMessage
{
    if ([cipherMessage isKindOfClass:[PreKeyWhisperMessage class]]) {
        return TSPreKeyWhisperMessageType;
    } else if ([cipherMessage isKindOfClass:[WhisperMessage class]]) {
        return TSEncryptedWhisperMessageType;
    }
    return TSUnknownMessageType;
}

- (void)saveMessage:(TSOutgoingMessage *)message withState:(TSOutgoingMessageState)state
{
    if (message.groupMetaMessage == TSGroupMessageDeliver || message.groupMetaMessage == TSGroupMessageNone) {
        [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            [message setMessageState:state];
            [message saveWithTransaction:transaction];
        }];
    }
}

- (void)saveGroupMessage:(TSOutgoingMessage *)message inThread:(TSThread *)thread
{
    if (message.groupMetaMessage == TSGroupMessageDeliver) {
        [self saveMessage:message withState:message.messageState];
    } else if (message.groupMetaMessage == TSGroupMessageQuit) {
        [[[TSInfoMessage alloc] initWithTimestamp:message.timestamp
                                         inThread:thread
                                      messageType:TSInfoMessageTypeGroupQuit
                                    customMessage:message.customMessage] save];
    } else {
        [[[TSInfoMessage alloc] initWithTimestamp:message.timestamp
                                         inThread:thread
                                      messageType:TSInfoMessageTypeGroupUpdate
                                    customMessage:message.customMessage] save];
    }
}

- (void)handleStaleDevicesWithResponse:(NSData *)responseData recipientId:(NSString *)identifier
{
    dispatch_async([OWSDispatch sendingQueue], ^{
        NSDictionary *serialization = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
        NSArray *devices = serialization[@"staleDevices"];

        if (!([devices count] > 0)) {
            return;
        }

        for (NSUInteger i = 0; i < [devices count]; i++) {
            int deviceNumber = [devices[i] intValue];
            [[TSStorageManager sharedManager] deleteSessionForContact:identifier deviceId:deviceNumber];
        }
    });
}

- (void)processException:(NSException *)exception
         outgoingMessage:(TSOutgoingMessage *)message
                inThread:(TSThread *)thread
{
    DDLogWarn(@"%@ Got exception: %@", self.tag, exception);

    [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        TSErrorMessage *errorMessage;

        if ([exception.name isEqualToString:UntrustedIdentityKeyException]) {
            errorMessage = [TSInvalidIdentityKeySendingErrorMessage
                untrustedKeyWithOutgoingMessage:message
                                       inThread:thread
                                   forRecipient:exception.userInfo[TSInvalidRecipientKey]
                                   preKeyBundle:exception.userInfo[TSInvalidPreKeyBundleKey]
                                withTransaction:transaction];
            message.messageState = TSOutgoingMessageStateUnsent;
            [message saveWithTransaction:transaction];
        } else if (message.groupMetaMessage == TSGroupMessageNone) {
            // Only update this with exception if it is not a group message as group
            // messages may except for one group
            // send but not another and the UI doesn't know how to handle that
            [message setMessageState:TSOutgoingMessageStateUnsent];
            [message saveWithTransaction:transaction];
        }

        [errorMessage saveWithTransaction:transaction];
    }];
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
