//  Created by Michael Kirk on 10/7/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

#import "OWSError.h"
#import "OWSFakeContactsManager.h"
#import "OWSFakeContactsUpdater.h"
#import "OWSFakeNetworkManager.h"
#import "OWSMessageSender.h"
#import "TSContactThread.h"
#import "TSMessagesManager.h"
#import "TSNetworkManager.h"
#import "TSOutgoingMessage.h"
#import "TSStorageManager+keyingMaterial.h"
#import "TSStorageManager.h"
#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSFakeMessagesManager : TSMessagesManager

@end

@implementation OWSFakeMessagesManager

- (NSArray<NSDictionary *> *)deviceMessages:(TSOutgoingMessage *)message
                               forRecipient:(SignalRecipient *)recipient
                                   inThread:(TSThread *)thread
{
    NSLog(@"[OWSFakeMessagesManager] Faking deviceMessages.");
    return @[];
}

@end

@interface OWSMessageSender (Testing)

- (void)setMessagesManager:(TSMessagesManager *)messagesManager;

@end

@implementation OWSMessageSender (Testing)

- (void)setMessagesManager:(TSMessagesManager *)messagesManager
{
    _messagesManager = messagesManager;
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
}

- (void)testExpiringMessageTimerStartsOnSuccess
{
    // Successful network manager
    TSNetworkManager *networkManager = [[OWSMessageSenderFakeNetworkManager alloc] initWithSuccess:YES];


    TSStorageManager *storageManager = [TSStorageManager sharedManager];
    OWSFakeContactsManager *contactsManager = [OWSFakeContactsManager new];
    OWSFakeContactsUpdater *contactsUpdater = [OWSFakeContactsUpdater new];

    OWSMessageSender *messageSender = [[OWSMessageSender alloc] initWithNetworkManager:networkManager
                                                                        storageManager:storageManager
                                                                       contactsManager:contactsManager
                                                                       contactsUpdater:contactsUpdater];

    TSMessagesManager *fakeMessagesManager = [[OWSFakeMessagesManager alloc] initWithNetworkManager:networkManager
                                                                                     storageManager:storageManager
                                                                                    contactsManager:contactsManager
                                                                                    contactsUpdater:contactsUpdater
                                                                                      messageSender:messageSender];
    messageSender.messagesManager = fakeMessagesManager;

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
    // Unsuccessful network manager
    TSNetworkManager *networkManager = [[OWSMessageSenderFakeNetworkManager alloc] initWithSuccess:NO];


    TSStorageManager *storageManager = [TSStorageManager sharedManager];
    OWSFakeContactsManager *contactsManager = [OWSFakeContactsManager new];
    OWSFakeContactsUpdater *contactsUpdater = [OWSFakeContactsUpdater new];

    OWSMessageSender *messageSender = [[OWSMessageSender alloc] initWithNetworkManager:networkManager
                                                                        storageManager:storageManager
                                                                       contactsManager:contactsManager
                                                                       contactsUpdater:contactsUpdater];

    TSMessagesManager *fakeMessagesManager = [[OWSFakeMessagesManager alloc] initWithNetworkManager:networkManager
                                                                                     storageManager:storageManager
                                                                                    contactsManager:contactsManager
                                                                                    contactsUpdater:contactsUpdater
                                                                                      messageSender:messageSender];
    messageSender.messagesManager = fakeMessagesManager;

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

    [self waitForExpectationsWithTimeout:5
                                 handler:^(NSError *error) {
                                     NSLog(@"Wasn't able to verify.");
                                 }];
}

@end

NS_ASSUME_NONNULL_END
