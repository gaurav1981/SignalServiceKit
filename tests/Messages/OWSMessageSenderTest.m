//  Created by Michael Kirk on 10/7/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

#import "OWSError.h"
#import "OWSFakeContactsManager.h"
#import "OWSFakeContactsUpdater.h"
#import "OWSFakeNetworkManager.h"
#import "OWSMessageSender.h"
#import "OWSUploadingService.h"
#import "TSContactThread.h"
#import "TSMessagesManager.h"
#import "TSNetworkManager.h"
#import "TSOutgoingMessage.h"
#import "TSStorageManager+keyingMaterial.h"
#import "TSStorageManager.h"
#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSMessageSender (Testing)

@property (nonatomic) OWSUploadingService *uploadingService;

@end

@implementation OWSMessageSender (Testing)

- (NSArray<NSDictionary *> *)deviceMessages:(TSOutgoingMessage *)message
                               forRecipient:(SignalRecipient *)recipient
                                   inThread:(TSThread *)thread
{
    NSLog(@"[OWSFakeMessagesManager] Faking deviceMessages.");
    return @[];
}

- (void)setUploadingService:(OWSUploadingService *)uploadingService
{
    _uploadingService = uploadingService;
}

- (OWSUploadingService *)uploadingService
{
    return _uploadingService;
}

@end

@interface OWSFakeUploadingService : OWSUploadingService

@property (nonatomic, readonly) BOOL shouldSucceed;

@end

@implementation OWSFakeUploadingService

- (instancetype)initWithSuccess:(BOOL)flag
{
    self = [super initWithNetworkManager:[OWSFakeNetworkManager new]];
    if (!self) {
        return self;
    }

    _shouldSucceed = flag;

    return self;
}

- (void)uploadAttachmentStream:(TSAttachmentStream *)attachmentStream
                       message:(TSOutgoingMessage *)outgoingMessage
                       success:(void (^)())successHandler
                       failure:(void (^)(NSError *error))failureHandler
{
    if (self.shouldSucceed) {
        successHandler();
    } else {
        failureHandler(OWSErrorMakeFailedToSendOutgoingMessageError());
    }
}

@end

@interface OWSFakeURLSessionDataTask : NSURLSessionDataTask

@property (copy) NSHTTPURLResponse *response;

- (instancetype)initWithStatusCode:(long)statusCode;

@end

@implementation OWSFakeURLSessionDataTask

@synthesize response = _response;

- (instancetype)initWithStatusCode:(long)statusCode
{
    self = [super init];

    if (!self) {
        return self;
    }

    NSURL *fakeURL = [NSURL URLWithString:@"http://127.0.0.1"];
    _response = [[NSHTTPURLResponse alloc] initWithURL:fakeURL statusCode:statusCode HTTPVersion:nil headerFields:nil];

    return self;
}

@end

@interface OWSMessageSenderFakeNetworkManager : OWSFakeNetworkManager

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithSuccess:(BOOL)shouldSucceed NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) BOOL shouldSucceed;

@end

@implementation OWSMessageSenderFakeNetworkManager

- (instancetype)initWithSuccess:(BOOL)shouldSucceed
{
    self = [super init];
    if (!self) {
        return self;
    }

    _shouldSucceed = shouldSucceed;

    return self;
}

- (void)makeRequest:(TSRequest *)request
            success:(void (^)(NSURLSessionDataTask *task, id responseObject))success
            failure:(void (^)(NSURLSessionDataTask *task, NSError *error))failure
{
    if ([request isKindOfClass:[TSSubmitMessageRequest class]]) {
        if (self.shouldSucceed) {
            success([NSURLSessionDataTask new], @{});
        } else {
            NSError *error
                = OWSErrorWithCodeDescription(OWSErrorCodeFailedToSendOutgoingMessage, @"fake error description");
            OWSFakeURLSessionDataTask *task = [[OWSFakeURLSessionDataTask alloc] initWithStatusCode:500];
            failure(task, error);
        }
    } else {
        [super makeRequest:request success:success failure:failure];
    }
}

@end

@interface OWSMessageSenderTest : XCTestCase

@property (nonatomic) TSThread *thread;
@property (nonatomic) TSOutgoingMessage *expiringMessage;
@property (nonatomic) OWSMessageSenderFakeNetworkManager *networkManager;
@property (nonatomic) OWSMessageSender *successfulMessageSender;
@property (nonatomic) OWSMessageSender *unsuccessfulMessageSender;

@end

@implementation OWSMessageSenderTest

- (void)setUp
{
    [super setUp];

    // Hack to make sure we don't explode when sending sync message.
    [TSStorageManager storePhoneNumber:@"+13231231234"];

    self.thread = [[TSContactThread alloc] initWithUniqueId:@"fake-thread-id"];
    [self.thread save];

    self.expiringMessage = [[TSOutgoingMessage alloc] initWithTimestamp:1
                                                               inThread:self.thread
                                                            messageBody:@"outgoing message"
                                                          attachmentIds:[NSMutableArray new]
                                                       expiresInSeconds:30];
    [self.expiringMessage save];


    TSStorageManager *storageManager = [TSStorageManager sharedManager];
    OWSFakeContactsManager *contactsManager = [OWSFakeContactsManager new];
    OWSFakeContactsUpdater *contactsUpdater = [OWSFakeContactsUpdater new];

    // Successful Sending
    TSNetworkManager *successfulNetworkManager = [[OWSMessageSenderFakeNetworkManager alloc] initWithSuccess:YES];
    self.successfulMessageSender = [[OWSMessageSender alloc] initWithNetworkManager:successfulNetworkManager
                                                                     storageManager:storageManager
                                                                    contactsManager:contactsManager
                                                                    contactsUpdater:contactsUpdater];

    // Unsuccessful Sending
    TSNetworkManager *unsuccessfulNetworkManager = [[OWSMessageSenderFakeNetworkManager alloc] initWithSuccess:NO];
    self.unsuccessfulMessageSender = [[OWSMessageSender alloc] initWithNetworkManager:unsuccessfulNetworkManager
                                                                       storageManager:storageManager
                                                                      contactsManager:contactsManager
                                                                      contactsUpdater:contactsUpdater];
}

- (void)testExpiringMessageTimerStartsOnSuccess
{
    OWSMessageSender *messageSender = self.successfulMessageSender;

    // Sanity Check
    XCTAssertEqual(0, self.expiringMessage.expiresAt);

    XCTestExpectation *messageStartedExpiration = [self expectationWithDescription:@"messageStartedExpiration"];
    [messageSender sendMessage:self.expiringMessage
        success:^() {
            if (self.expiringMessage.expiresAt > 0) {
                [messageStartedExpiration fulfill];
            } else {
                XCTFail(@"Message expiration was supposed to start.");
            }
        }
        failure:^(NSError *error) {
            XCTFail(@"Message failed to send");
        }];

    [self waitForExpectationsWithTimeout:5
                                 handler:^(NSError *error) {
                                     NSLog(@"Expiration timer not set in time.");
                                 }];
}

- (void)testExpiringMessageTimerDoesNotStartsOnFailure
{
    OWSMessageSender *messageSender = self.unsuccessfulMessageSender;

    // Sanity Check
    XCTAssertEqual(0, self.expiringMessage.expiresAt);

    XCTestExpectation *messageDidNotStartExpiration = [self expectationWithDescription:@"messageStartedExpiration"];
    [messageSender sendMessage:self.expiringMessage
        success:^() {
            XCTFail(@"Message sending was supposed to fail.");
        }
        failure:^(NSError *error) {
            if (self.expiringMessage.expiresAt == 0) {
                [messageDidNotStartExpiration fulfill];
            } else {
                XCTFail(@"Message expiration was not supposed to start.");
            }
        }];

    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testTextMessageIsMarkedAsSentOnSuccess
{
    OWSMessageSender *messageSender = self.successfulMessageSender;

    TSOutgoingMessage *message = [[TSOutgoingMessage alloc] initWithTimestamp:1
                                                                     inThread:self.thread
                                                                  messageBody:@"We want punks in the palace."];

    XCTestExpectation *markedAsSent = [self expectationWithDescription:@"markedAsSent"];
    [messageSender sendMessage:message
        success:^() {
            if (message.messageState == TSOutgoingMessageStateSent) {
                [markedAsSent fulfill];
            } else {
                XCTFail(@"Unexpected message state");
            }
        }
        failure:^(NSError *error) {
            XCTFail(@"sendMessage should succeed.");
        }];

    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testMediaMessageIsMarkedAsSentOnSuccess
{
    OWSMessageSender *messageSender = self.successfulMessageSender;
    messageSender.uploadingService = [[OWSFakeUploadingService alloc] initWithSuccess:YES];

    TSOutgoingMessage *message = [[TSOutgoingMessage alloc] initWithTimestamp:1
                                                                     inThread:self.thread
                                                                  messageBody:@"We want punks in the palace."];

    XCTestExpectation *markedAsSent = [self expectationWithDescription:@"markedAsSent"];
    [messageSender sendAttachmentData:[NSData new]
        contentType:@"image/gif"
        inMessage:message
        success:^() {
            if (message.messageState == TSOutgoingMessageStateSent) {
                [markedAsSent fulfill];
            } else {
                XCTFail(@"Unexpected message state");
            }
        }
        failure:^(NSError *error) {
            XCTFail(@"sendMessage should succeed.");
        }];

    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testTextMessageIsMarkedAsUnsentOnFailure
{
    OWSMessageSender *messageSender = self.unsuccessfulMessageSender;
    messageSender.uploadingService = [[OWSFakeUploadingService alloc] initWithSuccess:YES];

    TSOutgoingMessage *message = [[TSOutgoingMessage alloc] initWithTimestamp:1
                                                                     inThread:self.thread
                                                                  messageBody:@"We want punks in the palace."];

    XCTestExpectation *markedAsUnsent = [self expectationWithDescription:@"markedAsUnsent"];
    [messageSender sendMessage:message
        success:^() {
            XCTFail(@"sendMessage should fail.");
        }
        failure:^(NSError *error) {
            if (message.messageState == TSOutgoingMessageStateUnsent) {
                [markedAsUnsent fulfill];
            } else {
                XCTFail(@"Unexpected message state");
            }
        }];

    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testMediaMessageIsMarkedAsUnsentOnFailureToSend
{
    OWSMessageSender *messageSender = self.unsuccessfulMessageSender;
    // Assume that upload will go well, but that failure happens elsewhere in message sender.
    messageSender.uploadingService = [[OWSFakeUploadingService alloc] initWithSuccess:YES];

    TSOutgoingMessage *message = [[TSOutgoingMessage alloc] initWithTimestamp:1
                                                                     inThread:self.thread
                                                                  messageBody:@"We want punks in the palace."];

    XCTestExpectation *markedAsUnsent = [self expectationWithDescription:@"markedAsUnsent"];
    [messageSender sendAttachmentData:[NSData new]
        contentType:@"image/gif"
        inMessage:message
        success:^{
            XCTFail(@"sendMessage should fail.");
        }
        failure:^(NSError *_Nonnull error) {
            if (message.messageState == TSOutgoingMessageStateUnsent) {
                [markedAsUnsent fulfill];
            } else {
                XCTFail(@"Unexpected message state");
            }
        }];

    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testMediaMessageIsMarkedAsUnsentOnFailureToUpload
{
    OWSMessageSender *messageSender = self.successfulMessageSender;
    // Assume that upload fails, but other sending stuff would succeed.
    messageSender.uploadingService = [[OWSFakeUploadingService alloc] initWithSuccess:NO];

    TSOutgoingMessage *message = [[TSOutgoingMessage alloc] initWithTimestamp:1
                                                                     inThread:self.thread
                                                                  messageBody:@"We want punks in the palace."];

    XCTestExpectation *markedAsUnsent = [self expectationWithDescription:@"markedAsUnsent"];
    [messageSender sendAttachmentData:[NSData new]
        contentType:@"image/gif"
        inMessage:message
        success:^{
            XCTFail(@"sendMessage should fail.");
        }
        failure:^(NSError *_Nonnull error) {
            if (message.messageState == TSOutgoingMessageStateUnsent) {
                [markedAsUnsent fulfill];
            } else {
                XCTFail(@"Unexpected message state");
            }
        }];

    [self waitForExpectationsWithTimeout:5 handler:nil];
}


@end

NS_ASSUME_NONNULL_END
