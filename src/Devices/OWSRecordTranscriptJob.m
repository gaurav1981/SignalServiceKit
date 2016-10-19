//  Created by Michael Kirk on 9/23/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

#import "OWSRecordTranscriptJob.h"
#import "OWSAttachmentsProcessor.h"
#import "OWSDisappearingMessagesJob.h"
#import "OWSIncomingSentMessageTranscript.h"
#import "TSMessagesManager+sendMessages.h"
#import "TSOutgoingMessage.h"
#import "TSStorageManager.h"

NS_ASSUME_NONNULL_BEGIN


@interface OWSRecordTranscriptJob ()

@property (nonatomic, readonly) OWSIncomingSentMessageTranscript *incomingSentMessageTranscript;
@property (nonatomic, readonly) TSMessagesManager *messagesManager;
@property (nonatomic, readonly) TSNetworkManager *networkManager;

@end

@implementation OWSRecordTranscriptJob

- (instancetype)initWithMessagesManager:(TSMessagesManager *)messagesManager
          incomingSentMessageTranscript:(OWSIncomingSentMessageTranscript *)incomingSentMessageTranscript
{
    self = [super init];
    if (!self) {
        return self;
    }

    _messagesManager = messagesManager;
    _networkManager = messagesManager.networkManager;
    _incomingSentMessageTranscript = incomingSentMessageTranscript;

    return self;
}

- (void)runWithAttachmentHandler:(void (^)(TSAttachmentStream *attachmentStream))attachmentHandler
{
    OWSIncomingSentMessageTranscript *transcript = self.incomingSentMessageTranscript;
    DDLogDebug(@"%@ Recording transcript: %@", self.tag, transcript);
    TSThread *thread = transcript.thread;
    OWSAttachmentsProcessor *attachmentsProcessor =
    [[OWSAttachmentsProcessor alloc] initWithAttachmentProtos:transcript.attachmentPointerProtos
                                                    timestamp:transcript.timestamp
                                                        relay:transcript.relay
                                                       thread:thread
                                               networkManager:self.networkManager];

    // TODO group updates. Currently desktop doesn't support group updates, so not a problem yet.
    TSOutgoingMessage *outgoingMessage =
        [[TSOutgoingMessage alloc] initWithTimestamp:transcript.timestamp
                                            inThread:thread
                                         messageBody:transcript.body
                                       attachmentIds:[attachmentsProcessor.attachmentIds mutableCopy]
                                    expiresInSeconds:transcript.expirationDuration
                                     expireStartedAt:transcript.expirationStartedAt];

    if (transcript.isExpirationTimerUpdate) {
        [self.messagesManager becomeConsistentWithDisappearingConfigurationForMessage:outgoingMessage];
        // early return to avoid saving an empty incoming message.
        return;
    }

    [self.messagesManager handleMessageSentRemotely:outgoingMessage sentAt:transcript.expirationStartedAt];

    [attachmentsProcessor
        fetchAttachmentsForMessage:nil
                           success:attachmentHandler
                           failure:^(NSError *_Nonnull error) {
                               DDLogError(@"%@ failed to fetch transcripts attachments for message: %@",
                                   self.tag,
                                   outgoingMessage);
                           }];

    // If there is an attachment + text, render the text here, as Signal-iOS renders two messages.
    if (attachmentsProcessor.hasSupportedAttachments && transcript.body && ![transcript.body isEqualToString:@""]) {
        // render text *after* the attachment
        uint64_t textMessageTimestamp = transcript.timestamp + 1;
        TSOutgoingMessage *textMessage = [[TSOutgoingMessage alloc] initWithTimestamp:textMessageTimestamp
                                                                             inThread:thread
                                                                          messageBody:transcript.body
                                                                        attachmentIds:[NSMutableArray new]
                                                                     expiresInSeconds:transcript.expirationDuration
                                                                      expireStartedAt:transcript.expirationStartedAt];
        textMessage.messageState = TSOutgoingMessageStateDelivered;
        [textMessage save];
    }
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
