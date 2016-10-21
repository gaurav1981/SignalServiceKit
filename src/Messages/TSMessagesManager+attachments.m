//  Created by Frederic Jacobs on 17/12/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.

#import "Cryptography.h"
#import "MIMETypeUtil.h"
#import "NSDate+millisecondTimeStamp.h"
#import "OWSAttachmentsProcessor.h"
#import "TSAttachmentPointer.h"
#import "TSContactThread.h"
#import "TSGroupModel.h"
#import "TSGroupThread.h"
#import "TSInfoMessage.h"
#import "TSMessagesManager+attachments.h"
#import "TSNetworkManager.h"
#import <YapDatabase/YapDatabaseConnection.h>
#import <YapDatabase/YapDatabaseTransaction.h>

@interface TSMessagesManager ()

dispatch_queue_t attachmentsQueue(void);

@end

dispatch_queue_t attachmentsQueue() {
    static dispatch_once_t queueCreationGuard;
    static dispatch_queue_t queue;
    dispatch_once(&queueCreationGuard, ^{
      queue = dispatch_queue_create("org.whispersystems.signal.attachments", NULL);
    });
    return queue;
}

@implementation TSMessagesManager (attachments)

- (void)handleReceivedMediaWithEnvelope:(OWSSignalServiceProtosEnvelope *)envelope
                            dataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
{
    NSData *avatarGroupId;
    NSArray<OWSSignalServiceProtosAttachmentPointer *> *attachmentPointerProtos;
    if (dataMessage.hasGroup && (dataMessage.group.type == OWSSignalServiceProtosGroupContextTypeUpdate)) {
        avatarGroupId = dataMessage.group.id;
        attachmentPointerProtos = @[ dataMessage.group.avatar ];
    } else {
        attachmentPointerProtos = dataMessage.attachments;
    }

    TSThread *thread = [self threadForEnvelope:envelope dataMessage:dataMessage];

    OWSAttachmentsProcessor *attachmentsProcessor = [[OWSAttachmentsProcessor alloc]
        initWithAttachmentPointersProtos:attachmentPointerProtos
                               timestamp:envelope.timestamp
                                   relay:envelope.relay
                           avatarGroupId:avatarGroupId
                                inThread:thread
                         messagesManager:[TSMessagesManager sharedManager]]; // TODO self?

    if (attachmentsProcessor.hasSupportedAttachments) {
        TSIncomingMessage *possiblyCreatedMessage =
            [self handleReceivedEnvelope:envelope
                         withDataMessage:dataMessage
                           attachmentIds:attachmentsProcessor.supportedAttachmentIds];
        [attachmentsProcessor fetchAttachmentsForMessageId:possiblyCreatedMessage.uniqueId];
    }
}

- (void)sendTemporaryAttachment:(NSData *)attachmentData
                    contentType:(NSString *)contentType
                      inMessage:(TSOutgoingMessage *)outgoingMessage
                         thread:(TSThread *)thread
                        success:(successSendingCompletionBlock)successCompletionBlock
                        failure:(failedSendingCompletionBlock)failedCompletionBlock
{
    void (^successBlockWithDelete)() = ^{
        if (successCompletionBlock) {
            successCompletionBlock();
        }
        DDLogDebug(@"Removing temporary attachment message.");
        [outgoingMessage remove];
    };

    void (^failureBlockWithDelete)() = ^{
        if (failedCompletionBlock) {
            failedCompletionBlock();
        }
        DDLogDebug(@"Removing temporary attachment message.");
        [outgoingMessage remove];
    };

    [self sendAttachment:attachmentData
             contentType:contentType
               inMessage:outgoingMessage
                  thread:thread
                 success:successBlockWithDelete
                 failure:failureBlockWithDelete];
}

- (void)sendAttachment:(NSData *)attachmentData
           contentType:(NSString *)contentType
             inMessage:(TSOutgoingMessage *)outgoingMessage
                thread:(TSThread *)thread
               success:(successSendingCompletionBlock)successCompletionBlock
               failure:(failedSendingCompletionBlock)failedCompletionBlock
{
    outgoingMessage.messageState = TSOutgoingMessageStateAttemptingOut;
    [outgoingMessage save];

    // Should we have a separate stable id for the attachmentStream locally vs. what id the server gives us, since we
    // might never get there...
    TSAttachmentStream *attachmentStream = [[TSAttachmentStream alloc] initWithIdentifier:outgoingMessage.uniqueId
                                                                                     data:attachmentData
                                                                                      key:[NSData new]
                                                                              contentType:contentType];
    [attachmentStream save];
    [outgoingMessage.attachmentIds addObject:attachmentStream.uniqueId];
    [outgoingMessage save];

    TSRequest *allocateAttachment = [[TSAllocAttachmentRequest alloc] init];
    [self.networkManager makeRequest:allocateAttachment
        success:^(NSURLSessionDataTask *task, id responseObject) {
          dispatch_async(attachmentsQueue(), ^{
            if ([responseObject isKindOfClass:[NSDictionary class]]) {
                NSDictionary *responseDict = (NSDictionary *)responseObject;
                NSString *attachmentId = [(NSNumber *)[responseDict objectForKey:@"id"] stringValue];
                NSString *location         = [responseDict objectForKey:@"location"];

                TSAttachmentEncryptionResult *result =
                    [Cryptography encryptAttachment:attachmentData contentType:contentType identifier:attachmentId];
                result.pointer.isDownloaded = NO;
                [result.pointer save];
                outgoingMessage.body = nil;
                [outgoingMessage.attachmentIds addObject:attachmentId];
                if (outgoingMessage.groupMetaMessage != TSGroupMessageNew &&
                    outgoingMessage.groupMetaMessage != TSGroupMessageUpdate) {
                    [outgoingMessage setMessageState:TSOutgoingMessageStateAttemptingOut];
                    [outgoingMessage save];
                }
                BOOL success = [self uploadDataWithProgress:result.body location:location attachmentID:attachmentId];
                if (success) {
                    result.pointer.isDownloaded = YES;
                    [result.pointer save];
                    [self sendMessage:outgoingMessage
                        inThread:thread
                        success:^{
                          if (successCompletionBlock) {
                              successCompletionBlock();
                          }
                        }
                        failure:^{
                          if (failedCompletionBlock) {
                              failedCompletionBlock();
                          }
                        }];
                } else {
                    if (failedCompletionBlock) {
                        failedCompletionBlock();
                    }
                    DDLogWarn(@"Failed to upload attachment");
                }
            } else {
                if (failedCompletionBlock) {
                    failedCompletionBlock();
                }
                DDLogError(@"The server didn't returned an empty responseObject");
            }
          });
        }
        failure:^(NSURLSessionDataTask *task, NSError *error) {
          if (failedCompletionBlock) {
              failedCompletionBlock();
          }
          DDLogError(@"Failed to get attachment allocated: %@", error);
        }];
}

- (void)sendAttachment:(NSData *)attachmentData
           contentType:(NSString *)contentType
                thread:(TSThread *)thread
               success:(successSendingCompletionBlock)successCompletionBlock
               failure:(failedSendingCompletionBlock)failedCompletionBlock
{
    TSOutgoingMessage *message = [[TSOutgoingMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                                     inThread:thread
                                                                  messageBody:nil
                                                                attachmentIds:[NSMutableArray new]];
    [self sendAttachment:attachmentData
             contentType:contentType
               inMessage:message
                  thread:thread
                 success:successCompletionBlock
                 failure:failedCompletionBlock];
}

- (void)retrieveAttachment:(TSAttachmentPointer *)attachment messageId:(NSString *)messageId {
    [self setAttachment:attachment isDownloadingInMessage:messageId];

    TSAttachmentRequest *attachmentRequest =
        [[TSAttachmentRequest alloc] initWithId:[attachment identifier] relay:attachment.relay];

    [self.networkManager makeRequest:attachmentRequest
        success:^(NSURLSessionDataTask *task, id responseObject) {
          if ([responseObject isKindOfClass:[NSDictionary class]]) {
              dispatch_async(attachmentsQueue(), ^{
                NSString *location = [(NSDictionary *)responseObject objectForKey:@"location"];

                NSData *data = [self downloadFromLocation:location pointer:attachment messageId:messageId];
                if (data) {
                    [self decryptedAndSaveAttachment:attachment data:data messageId:messageId];
                }
              });
          } else {
              DDLogError(@"Failed retrieval of attachment. Response had unexpected format.");
              [self setFailedAttachment:attachment inMessage:messageId];
          }
        }
        failure:^(NSURLSessionDataTask *task, NSError *error) {
          DDLogError(@"Failed retrieval of attachment with error: %@", error.description);
          [self setFailedAttachment:attachment inMessage:messageId];
        }];
}

- (void)setAttachment:(TSAttachmentPointer *)pointer isDownloadingInMessage:(NSString *)messageId {
    [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
      [pointer setDownloading:YES];
      [pointer saveWithTransaction:transaction];
      TSMessage *message = [TSMessage fetchObjectWithUniqueID:messageId transaction:transaction];
      [message saveWithTransaction:transaction];
    }];
}

- (void)setFailedAttachment:(TSAttachmentPointer *)pointer inMessage:(NSString *)messageId {
    [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
      [pointer setDownloading:NO];
      [pointer setFailed:YES];
      [pointer saveWithTransaction:transaction];
      TSMessage *message = [TSMessage fetchObjectWithUniqueID:messageId transaction:transaction];
      [message saveWithTransaction:transaction];
    }];
}

- (void)decryptedAndSaveAttachment:(TSAttachmentPointer *)attachment
                              data:(NSData *)cipherText
                         messageId:(NSString *)messageId
{
    NSData *plaintext = [Cryptography decryptAttachment:cipherText withKey:attachment.encryptionKey];

    if (!plaintext) {
        DDLogError(@"Failed to get attachment decrypted ...");
    } else {
        TSAttachmentStream *stream = [[TSAttachmentStream alloc] initWithIdentifier:attachment.uniqueId
                                                                               data:plaintext
                                                                                key:attachment.encryptionKey
                                                                        contentType:attachment.contentType];

        [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
          [stream saveWithTransaction:transaction];
          if ([attachment.avatarOfGroupId length] != 0) {
              TSGroupModel *emptyModelToFillOutId =
                  [[TSGroupModel alloc] initWithTitle:nil memberIds:nil image:nil groupId:attachment.avatarOfGroupId];
              TSGroupThread *gThread =
                  [TSGroupThread getOrCreateThreadWithGroupModel:emptyModelToFillOutId transaction:transaction];

              gThread.groupModel.groupImage = [stream image];
              // Avatars are stored directly in the database, so there's no need to keep the attachment around after
              // assigning the image.
              [stream removeWithTransaction:transaction];

              [[TSMessage fetchObjectWithUniqueID:messageId] saveWithTransaction:transaction];
              [gThread saveWithTransaction:transaction];
          } else {
              // Causing message to be reloaded in view.
              TSMessage *message = [TSMessage fetchObjectWithUniqueID:messageId transaction:transaction];
              [message saveWithTransaction:transaction];
          }
        }];
    }
}

- (NSData *)downloadFromLocation:(NSString *)location
                         pointer:(TSAttachmentPointer *)pointer
                       messageId:(NSString *)messageId {
    __block NSData *data;

    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    manager.requestSerializer     = [AFHTTPRequestSerializer serializer];
    [manager.requestSerializer setValue:OWSMimeTypeApplicationOctetStream forHTTPHeaderField:@"Content-Type"];
    manager.responseSerializer = [AFHTTPResponseSerializer serializer];
    manager.completionQueue    = dispatch_get_main_queue();

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    [manager GET:location
        parameters:nil
        progress:nil
        success:^(NSURLSessionDataTask *_Nonnull task, id _Nullable responseObject) {
          data = responseObject;
          dispatch_semaphore_signal(sema);
        }
        failure:^(NSURLSessionDataTask *_Nullable task, NSError *_Nonnull error) {
          DDLogError(@"Failed to retrieve attachment with error: %@", error.description);
          if (pointer && messageId) {
              [self setFailedAttachment:pointer inMessage:messageId];
          }
          dispatch_semaphore_signal(sema);
        }];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    return data;
}

- (BOOL)uploadDataWithProgress:(NSData *)cipherText
                      location:(NSString *)location
                  attachmentID:(NSString *)attachmentID {
    // AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    // manager.responseSerializer    = [AFHTTPResponseSerializer serializer];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL success      = NO;

    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:location]];
    request.HTTPMethod           = @"PUT";
    request.HTTPBody             = cipherText;
    [request setValue:OWSMimeTypeApplicationOctetStream forHTTPHeaderField:@"Content-Type"];

    AFURLSessionManager *manager = [[AFURLSessionManager alloc]
        initWithSessionConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];

    NSURLSessionUploadTask *uploadTask;
    uploadTask = [manager uploadTaskWithRequest:request
        fromData:cipherText
        progress:^(NSProgress *_Nonnull uploadProgress) {
          NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
          [notificationCenter postNotificationName:@"attachmentUploadProgress"
                                            object:nil
                                          userInfo:@{
                                              @"progress" : @(uploadProgress.fractionCompleted),
                                              @"attachmentID" : attachmentID
                                          }];
        }
        completionHandler:^(NSURLResponse *_Nonnull response, id _Nullable responseObject, NSError *_Nullable error) {
          NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
          BOOL isValidResponse = (statusCode >= 200) && (statusCode < 400);
          if (!error && isValidResponse) {
              success = YES;
              dispatch_semaphore_signal(sema);
          } else {
              DDLogError(@"Failed uploading attachment with error: %@", error.description);
              success = NO;
              dispatch_semaphore_signal(sema);
          }
        }];

    [uploadTask resume];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    return success;
}

@end
