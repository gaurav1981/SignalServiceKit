//  Created by Frederic Jacobs on 17/12/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.

#import "Cryptography.h"
#import "MIMETypeUtil.h"
#import "NSDate+millisecondTimeStamp.h"
#import "OWSAttachmentsProcessor.h"
#import "OWSDispatch.h"
#import "OWSUploadingService.h"
#import "TSAttachmentPointer.h"
#import "TSContactThread.h"
#import "TSGroupModel.h"
#import "TSGroupThread.h"
#import "TSInfoMessage.h"
#import "TSMessagesManager+attachments.h"
#import "TSNetworkManager.h"
#import <YapDatabase/YapDatabaseConnection.h>
#import <YapDatabase/YapDatabaseTransaction.h>

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

    OWSAttachmentsProcessor *attachmentsProcessor =
        [[OWSAttachmentsProcessor alloc] initWithAttachmentPointersProtos:attachmentPointerProtos
                                                                timestamp:envelope.timestamp
                                                                    relay:envelope.relay
                                                            avatarGroupId:avatarGroupId
                                                                 inThread:thread
                                                          messagesManager:self];

    if (attachmentsProcessor.hasSupportedAttachments) {
        TSIncomingMessage *possiblyCreatedMessage =
            [self handleReceivedEnvelope:envelope
                         withDataMessage:dataMessage
                           attachmentIds:attachmentsProcessor.supportedAttachmentIds];
        [attachmentsProcessor fetchAttachmentsForMessageId:possiblyCreatedMessage.uniqueId];
    }
}

- (void)retrieveAttachment:(TSAttachmentPointer *)attachment messageId:(NSString *)messageId {
    [self setAttachment:attachment isDownloadingInMessage:messageId];

    TSAttachmentRequest *attachmentRequest =
        [[TSAttachmentRequest alloc] initWithId:attachment.serverId relay:attachment.relay];

    [self.networkManager makeRequest:attachmentRequest
        success:^(NSURLSessionDataTask *task, id responseObject) {
          if ([responseObject isKindOfClass:[NSDictionary class]]) {
              dispatch_async([OWSDispatch attachmentsQueue], ^{
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
        TSAttachmentStream *stream =
            [[TSAttachmentStream alloc] initWithData:plaintext contentType:attachment.contentType];

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

@end
