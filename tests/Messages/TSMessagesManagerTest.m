//  Created by Michael Kirk on 9/23/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

#import <XCTest/XCTest.h>

#import "ContactsManagerProtocol.h"
#import "ContactsUpdater.h"
#import "OWSFakeContactsManager.h"
#import "OWSFakeContactsUpdater.h"
#import "OWSFakeNetworkManager.h"
#import "OWSMessageSender.h"
#import "OWSSignalServiceProtos.pb.h"
#import "TSMessagesManager.h"
#import "TSNetworkManager.h"
#import "TSStorageManager.h"
#import "objc/runtime.h"

@interface TSMessagesManagerTest : XCTestCase

@end

@interface TSMessagesManager (Testing)

// private method we are testing
- (void)handleIncomingEnvelope:(OWSSignalServiceProtosEnvelope *)messageEnvelope
               withSyncMessage:(OWSSignalServiceProtosSyncMessage *)syncMessage;

@end

@interface OWSFakeMessageSender : OWSMessageSender

@property (nonatomic, readonly) XCTestExpectation *expectation;

@end

@implementation OWSFakeMessageSender

- (instancetype)initWithExpectation:(XCTestExpectation *)expectation
{
    self = [super init];
    if (!self) {
        return self;
    }

    _expectation = expectation;

    return self;
}

- (void)sendTemporaryAttachmentData:(NSData *)attachmentData
                        contentType:(NSString *)contentType
                          inMessage:(TSOutgoingMessage *)outgoingMessage
                            success:(void (^)())successHandler
                            failure:(void (^)(NSError *error))failureHandler
{

    NSLog(@"Faking sendTemporyAttachmentData.");
    [self.expectation fulfill];
    successHandler();
}

@end

@implementation TSMessagesManagerTest

- (void)testIncomingSyncContactMessage
{
    XCTestExpectation *messageWasSent = [self expectationWithDescription:@"message was sent"];

    OWSFakeMessageSender *messageSender = [[OWSFakeMessageSender alloc] initWithExpectation:messageWasSent];

    TSMessagesManager *messagesManager =
        [[TSMessagesManager alloc] initWithNetworkManager:[OWSFakeNetworkManager new]
                                           storageManager:[TSStorageManager sharedManager]
                                          contactsManager:[OWSFakeContactsManager new]
                                          contactsUpdater:[OWSFakeContactsUpdater new]
                                            messageSender:messageSender];

    OWSSignalServiceProtosEnvelopeBuilder *envelopeBuilder = [OWSSignalServiceProtosEnvelopeBuilder new];
    OWSSignalServiceProtosSyncMessageBuilder *messageBuilder = [OWSSignalServiceProtosSyncMessageBuilder new];
    OWSSignalServiceProtosSyncMessageRequestBuilder *requestBuilder =
        [OWSSignalServiceProtosSyncMessageRequestBuilder new];
    [requestBuilder setType:OWSSignalServiceProtosSyncMessageRequestTypeGroups];
    [messageBuilder setRequest:[requestBuilder build]];

    [messagesManager handleIncomingEnvelope:[envelopeBuilder build] withSyncMessage:[messageBuilder build]];

    [self waitForExpectationsWithTimeout:5
                                 handler:^(NSError *error) {
                                     NSLog(@"No message submitted.");
                                 }];
}

@end
