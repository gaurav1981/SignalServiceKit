//  Created by Michael Kirk on 9/23/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

#import "NSDate+millisecondTimeStamp.h"
#import "OWSDisappearingMessagesFinder.h"
#import "OWSDisappearingMessagesJob.h"
#import "TSMessage.h"
#import "TSStorageManager.h"
#import "TSThread.h"
#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSDisappearingMessagesJobTest : XCTestCase

@end

@implementation OWSDisappearingMessagesJobTest

- (void)setUp
{
    [super setUp];
    [TSMessage removeAllObjectsInCollection];
}

- (void)testRemoveAnyExpiredMessage
{
    TSThread *thread = [TSThread new];
    uint64_t now = [NSDate ows_millisecondTimeStamp];
    TSMessage *expiredMessage1 = [[TSMessage alloc] initWithTimestamp:1
                                                             inThread:thread
                                                          messageBody:@"expiredMessage1"
                                                        attachmentIds:@[]
                                                     expiresInSeconds:1
                                                      expireStartedAt:now - 20000];
    [expiredMessage1 save];

    TSMessage *expiredMessage2 = [[TSMessage alloc] initWithTimestamp:1
                                                             inThread:thread
                                                          messageBody:@"expiredMessage2"
                                                        attachmentIds:@[]
                                                     expiresInSeconds:2
                                                      expireStartedAt:now - 2001];
    [expiredMessage2 save];

    TSMessage *notYetExpiredMessage = [[TSMessage alloc] initWithTimestamp:1
                                                                  inThread:thread
                                                               messageBody:@"notYetExpiredMessage"
                                                             attachmentIds:@[]
                                                          expiresInSeconds:20
                                                           expireStartedAt:now - 10000];
    [notYetExpiredMessage save];

    TSMessage *unExpiringMessage = [[TSMessage alloc] initWithTimestamp:1
                                                               inThread:thread
                                                            messageBody:@"unexpiringMessage"
                                                          attachmentIds:@[]
                                                       expiresInSeconds:0
                                                        expireStartedAt:0];
    [unExpiringMessage save];

    OWSDisappearingMessagesJob *job =
        [[OWSDisappearingMessagesJob alloc] initWithStorageManager:[TSStorageManager sharedManager]];

    // Sanity Check.
    XCTAssertEqual(4, [TSMessage numberOfKeysInCollection]);
    [job run];
    XCTAssertEqual(2, [TSMessage numberOfKeysInCollection]);
}

@end

NS_ASSUME_NONNULL_END
