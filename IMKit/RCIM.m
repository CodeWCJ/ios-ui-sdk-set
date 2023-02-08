//
//  RCIM.m
//  RongIMKit
//
//  Created by xugang on 15/1/13.
//  Copyright (c) 2015年 RongCloud. All rights reserved.
//

#import "RCIM.h"
#import "RCKitUtility.h"
#import "RCLocalNotification.h"
#import "RCOldMessageNotificationMessage.h"
#import "RCSystemSoundPlayer.h"
#import "RCUserInfoCacheManager.h"
#import "RCUserInfoUpdateMessage.h"
#import "RongExtensionKit.h"
#import "RongIMKitExtensionManager.h"
#import "RCHQVoiceMsgDownloadManager.h"
#import "RCKitCommonDefine.h"
#import "RCKitConfig.h"
#import "RCIM+Deprecated.h"
#import <AVFoundation/AVFoundation.h>
#import "RCResendManager.h"
#import <RongDiscussion/RongDiscussion.h>
#import <RongPublicService/RongPublicService.h>
#import "RCKitListenerManager.h"
#import "RCMessageNotificationHelper.h"
#import "RCIMNotificationDataContext.h"

NSString *const RCKitDispatchMessageNotification = @"RCKitDispatchMessageNotification";
NSString *const RCKitDispatchTypingMessageNotification = @"RCKitDispatchTypingMessageNotification";
NSString *const RCKitSendingMessageNotification = @"RCKitSendingMessageNotification";
NSString *const RCKitDispatchConnectionStatusChangedNotification = @"RCKitDispatchConnectionStatusChangedNotification";
NSString *const RCKitDispatchRecallMessageNotification = @"RCKitDispatchRecallMessageNotification";
NSString *const RCKitDispatchRecallMessageDetailNotification = @"RCKitDispatchRecallMessageDetailNotification";

NSString *const RCKitDispatchDownloadMediaNotification = @"RCKitDispatchDownloadMediaNotification";
NSString *const RCKitDispatchMessageReceiptRequestNotification = @"RCKitDispatchMessageReceiptRequestNotification";

NSString *const RCKitDispatchMessageReceiptResponseNotification = @"RCKitDispatchMessageReceiptResponseNotification";
NSString *const RCKitMessageDestructingNotification = @"RCKitMessageDestructingNotification";
NSString *const RCKitDispatchConversationStatusChangeNotification =
    @"RCKitDispatchConversationStatusChangeNotification";

@interface RCIM () <RCIMClientReceiveMessageDelegate, RCConnectionStatusChangeDelegate, RCMessageDestructDelegate,
                    RCConversationStatusChangeDelegate>
@property (nonatomic, copy) NSString *appKey;
@property (nonatomic, strong) NSDate *notificationQuietBeginTime;
@property (nonatomic, strong) NSDate *notificationQuietEndTime;
@property (nonatomic, assign) BOOL hasNotifydExtensionModuleUserId;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, strong) NSMutableArray *downloadingMeidaMessageIds;
@end

static RCIM *__rongUIKit = nil;
static NSString *const RCIMKitVersion = @"5.3.5_opensource";
@implementation RCIM

+ (instancetype)sharedRCIM {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (__rongUIKit == nil) {
            __rongUIKit = [[RCIM alloc] init];
            __rongUIKit.userInfoDataSource = nil;
            __rongUIKit.groupUserInfoDataSource = nil;
            __rongUIKit.groupInfoDataSource = nil;
            __rongUIKit.enableMessageAttachUserInfo = NO;
            __rongUIKit.enablePersistentUserInfoCache = NO;
            __rongUIKit.hasNotifydExtensionModuleUserId = NO;
            __rongUIKit.automaticDownloadHQVoiceMsgEnable = YES;
            [[RongIMKitExtensionManager sharedManager] loadAllExtensionModules];
        }
    });
    return __rongUIKit;
}

+ (void)load{
    [RCUtilities setModuleName:@"imkit" version:[self getVersion]];
}

- (void)setCurrentUserInfo:(RCUserInfo *)currentUserInfo {
    [[RCIMClient sharedRCIMClient] setCurrentUserInfo:currentUserInfo];
    if (currentUserInfo) {
        [[RCUserInfoCacheManager sharedManager] updateUserInfo:currentUserInfo forUserId:currentUserInfo.userId];
        [RCUserInfoCacheManager sharedManager].currentUserId = currentUserInfo.userId;
    }
}

- (RCUserInfo *)currentUserInfo {
    return [RCIMClient sharedRCIMClient].currentUserInfo;
}

- (void)setGroupUserInfoDataSource:(id<RCIMGroupUserInfoDataSource>)groupUserInfoDataSource {
    _groupUserInfoDataSource = groupUserInfoDataSource;
    if (groupUserInfoDataSource) {
        [RCUserInfoCacheManager sharedManager].groupUserInfoEnabled = YES;
    }
}

- (void)initWithAppKey:(NSString *)appKey {
    if ([self.appKey isEqual:appKey]) {
        NSLog(@"Warning:请不要重复调用Init！！！");
        return;
    }

    self.appKey = appKey;
    [[RCIMClient sharedRCIMClient] initWithAppKey:appKey];

    [self registerMessageType:[RCOldMessageNotificationMessage class]];
    // listen receive message
    [[RCIMClient sharedRCIMClient] setReceiveMessageDelegate:self object:nil];
    [[RCIMClient sharedRCIMClient] setRCConnectionStatusChangeDelegate:self];
    [[RCIMClient sharedRCIMClient] setRCMessageDestructDelegate:self];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(resetNotificationQuietStatus)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(resetNotificationQuietStatus)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(resetNotificationQuietStatus)
                                                 name:@"RCLibDispatchResetNotificationQuietStatusNotification"
                                               object:nil];

    [self registerMessageType:RCUserInfoUpdateMessage.class];
    [RCUserInfoCacheManager sharedManager].appKey = appKey;

    [[RongIMKitExtensionManager sharedManager] initWithAppKey:appKey];
    [[RCIMClient sharedRCIMClient] setRCConversationStatusChangeDelegate:self];
}

- (void)setReceiveMessageDelegate:(id<RCIMReceiveMessageDelegate>)receiveMessageDelegate {
    [self addReceiveMessageDelegate:receiveMessageDelegate];
}

- (id<RCIMReceiveMessageDelegate>)receiveMessageDelegate {
    NSArray *receiveDelegates = [[RCKitListenerManager sharedManager] allReceiveMessageDelegates];
    if (receiveDelegates.count > 0) {
        return receiveDelegates.firstObject;
    }
    return nil;
}

- (void)addReceiveMessageDelegate:(id<RCIMReceiveMessageDelegate>)delegate {
    [[RCKitListenerManager sharedManager] addReceiveMessageDelegate:delegate];
}

- (void)removeReceiveMessageDelegate:(id<RCIMReceiveMessageDelegate>)delegate {
    [[RCKitListenerManager sharedManager] removeReceiveMessageDelegate:delegate];
}

- (void)resetNotificationQuietStatus {
    [[RCChannelClient sharedChannelManager] getNotificationQuietHoursLevel:^(NSString * _Nonnull startTime, int spanMins, RCPushNotificationQuietHoursLevel level) {
        NSDateFormatter *dateFormatter = [self getDateFormatter];
        if (startTime && startTime.length != 0) {
            self.notificationQuietBeginTime = [dateFormatter dateFromString:startTime];
            self.notificationQuietEndTime = [self.notificationQuietBeginTime dateByAddingTimeInterval:spanMins * 60];
        } else {
            self.notificationQuietBeginTime = nil;
            self.notificationQuietEndTime = nil;
        }
    } error:^(RCErrorCode status) {
        
    }];
}

- (BOOL)checkNoficationQuietStatus {
    BOOL isNotificationQuiet = NO;
    if (self.notificationQuietBeginTime && self.notificationQuietEndTime) {
        NSDateFormatter *dateFormatter = [self getDateFormatter];
        NSString *nowDateString = [dateFormatter stringFromDate:[NSDate date]];
        NSDate *nowDate = [dateFormatter dateFromString:nowDateString];
        long long beginTime = self.notificationQuietBeginTime.timeIntervalSince1970;
        long long nowTime = nowDate.timeIntervalSince1970;
        long long endTime = self.notificationQuietEndTime.timeIntervalSince1970;
        if (nowTime < beginTime) {
            nowTime = nowTime + 24 * 60 * 60;
        }
        if (nowTime > beginTime && nowTime < endTime) {
            isNotificationQuiet = YES;
        }
    }
    return isNotificationQuiet;
}

- (NSDateFormatter *)getDateFormatter {
    static NSDateFormatter *dateFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"HH:mm:ss"];
    });
    return dateFormatter;
}

- (void)registerMessageType:(Class)messageClass {
    [[RCIMClient sharedRCIMClient] registerMessageType:messageClass];
}

- (void)connectWithToken:(NSString *)token
                dbOpened:(void (^)(RCDBErrorCode code))dbOpenedBlock
                 success:(void (^)(NSString *userId))successBlock
                   error:(void (^)(RCConnectErrorCode status))errorBlock {
    [self connectWithToken:token timeLimit:-1 dbOpened:dbOpenedBlock success:successBlock error:errorBlock];
}

- (void)connectWithToken:(NSString *)token
               timeLimit:(int)timeLimit
                dbOpened:(void (^)(RCDBErrorCode code))dbOpenedBlock
                 success:(void (^)(NSString *userId))successBlock
                   error:(void (^)(RCConnectErrorCode errorCode))errorBlock {
    [[RCCoreClient sharedCoreClient] connectWithToken:token timeLimit:timeLimit dbOpened:dbOpenedBlock success:^(NSString *userId) {
            [RCUserInfoCacheManager sharedManager].currentUserId = userId;
            if (successBlock) {
                successBlock(userId);
            }
        
            // 重新读取免打扰配置
            [self resetNotificationQuietStatus];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.hasNotifydExtensionModuleUserId) {
                    self.hasNotifydExtensionModuleUserId = YES;
                    NSString *userId = [[RCIMClient sharedRCIMClient].currentUserInfo.userId copy];
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        [[RongIMKitExtensionManager sharedManager] didConnect:userId];
                    });
                }
            });
        } error:^(RCConnectErrorCode errorCode) {
            NSString *userId = [[RCIMClient sharedRCIMClient].currentUserInfo.userId copy];
            if (userId) {
                [RCUserInfoCacheManager sharedManager].currentUserId = userId;
            }
            if (errorBlock != nil)
                errorBlock(errorCode);
        }];
    if ([RCIMClient sharedRCIMClient].currentUserInfo.userId.length > 0) {
        self.currentUserInfo = [RCIMClient sharedRCIMClient].currentUserInfo;
    }
}

/**
 *  断开连接。
 *
 *  @param isReceivePush 是否接收回调。
 */
- (void)disconnect:(BOOL)isReceivePush {
    self.hasNotifydExtensionModuleUserId = NO;
    [[RongIMKitExtensionManager sharedManager] didDisconnect];
    [[RCIMClient sharedRCIMClient] disconnect:isReceivePush];
}

/**
 *  断开连接。
 */
- (void)disconnect {
    [self disconnect:YES];
}

/**
 *  Log out。不会接收到push消息。
 */
- (void)logout {
    [self disconnect:NO];
}

- (void)postLocalNotificationIfNeed:(RCMessage *)message {
    
    //聊天室消息不做本地通知
    if (ConversationType_CHATROOM == message.conversationType) {
        
        return;
    }
    //在 IMKit 明确不支持超级群的情况下，超级群消息不做本地通知
    //后续如果 IMKit 明确支持超级群，此限制需放开
    if (ConversationType_ULTRAGROUP == message.conversationType) {
        return;
    }
    
    //离线消息或者消息关闭通知，不做本地通知
    if (message.isOffLine || message.messageConfig.disableNotification) {
        return;
    }
    
    //APP在前台，不做本地通知
    if (RCSDKRunningMode_Background != [RCIMClient sharedRCIMClient].sdkRunningMode) {
        return;
    }
    
    //@me 要做本地通知
    // 这个地方有冲突 @me  @other  @all 如何处理
    NSDictionary *dictionary = [RCKitUtility getNotificationUserInfoDictionary:message];
//    if (message.content.mentionedInfo.isMentionedMe) {
//        [[RCLocalNotification defaultCenter] postLocalNotificationWithMessage:message userInfo:dictionary];
//        return;
//    }

    //全局禁止本地通知，不做本地通知
    if (RCKitConfigCenter.message.disableMessageNotificaiton) {
        return;
    }
    
    //用户开启免打扰，不做本地通知
//    if ([self checkNoficationQuietStatus]) {
//        return;
//    }
    
    if ([message.content isKindOfClass:RCCommandNotificationMessage.class]){
        return;
    }
    
    if (message.conversationType == ConversationType_Encrypted) {
        [RCMessageNotificationHelper checkNotifyAbilityWith:message completion:^(BOOL show) {
            if (show) {
                [[RCLocalNotification defaultCenter]
                 postLocalNotification:RCLocalizedString(@"receive_new_message")
                 userInfo:dictionary];
            }
        }];
    } else {
        [RCMessageNotificationHelper checkNotifyAbilityWith:message completion:^(BOOL show) {
            if (show) {
                [[RCLocalNotification defaultCenter] postLocalNotificationWithMessage:message
                                                                             userInfo:dictionary];

            }
        }];
    }
    /*
    if (message.conversationType == ConversationType_Encrypted) {
        [[RCLocalNotification defaultCenter]
         postLocalNotification:RCLocalizedString(@"receive_new_message")
         userInfo:dictionary];
    } else {
        [[RCChannelClient sharedChannelManager]
         getConversationNotificationStatus:message.conversationType
         targetId:message.targetId
         channelId:message.channelId
         success:^(RCConversationNotificationStatus nStatus) {
            if (NOTIFY == nStatus) {
                [[RCLocalNotification defaultCenter] postLocalNotificationWithMessage:message userInfo:dictionary];
            }
        } error:nil];
    }
*/
}

- (void)onReceived:(RCMessage *)message left:(int)nLeft object:(id)object {
    for (id<RCIMReceiveMessageDelegate> delegate in [[RCKitListenerManager sharedManager] allReceiveMessageDelegates]) {
        if ([delegate respondsToSelector:@selector(interceptMessage:)] && [delegate interceptMessage:message]) {
            return;
        }
    }
    if (!message) {
        return;
    }
    
    if ([self p_updateUserInfoCache:message.content]){
        return;
    }

    if ([message.content isKindOfClass:RCHQVoiceMessage.class] && nLeft == 0 &&
        self.automaticDownloadHQVoiceMsgEnable) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[RCHQVoiceMsgDownloadManager defaultManager] pushVoiceMsgs:@[ message ] priority:NO];
        });
    }

    if (message.conversationType == ConversationType_APPSERVICE ||
        message.conversationType == ConversationType_PUBLICSERVICE) {
        if (![RCIM sharedRCIM].publicServiceInfoDataSource) {
            if (![[RCIMClient sharedRCIMClient] getConversation:message.conversationType targetId:message.targetId]) {
                //如果收到了公众账号消息, 但是没有取到相应的公众账号信息, 导致没有创建会话, 这时候先不进行任何UI刷新
                return;
            }
        }
    }
    NSDictionary *dic_left = @{ @"left" : @(nLeft) };
    for (id<RCIMReceiveMessageDelegate> delegate in [[RCKitListenerManager sharedManager] allReceiveMessageDelegates]) {
        if ([delegate respondsToSelector:@selector(onRCIMReceiveMessage:left:)]) {
            [delegate onRCIMReceiveMessage:message left:nLeft];
        }
    }
    // dispatch message
    [[RongIMKitExtensionManager sharedManager] onMessageReceived:message];

    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchMessageNotification
                                                        object:message
                                                      userInfo:dic_left];
    
    if ([self p_disbaleCustomMessageAlert:message left:nLeft]){
        return;
    }
    
    // 调用声音提示-内部有判断逻辑
    [self playSoundByMessageIfNeed:message];
    
    
    // 调用展示通知-内部有判断逻辑
    [self postLocalNotificationIfNeed:message];
}

- (BOOL)p_updateUserInfoCache:(RCMessageContent *)messageContent{
    RCUserInfo *senderUserInfo = messageContent.senderUserInfo;
    if (senderUserInfo.userId) {
        if (![senderUserInfo.userId isEqualToString:[RCIMClient sharedRCIMClient].currentUserInfo.userId]) {
            if (senderUserInfo.name.length > 0 || senderUserInfo.portraitUri.length > 0) {
                if (senderUserInfo.portraitUri == nil || [RCUtilities isLocalPath:senderUserInfo.portraitUri]) {
                    RCUserInfo *userInfo = [[RCUserInfoCacheManager sharedManager]
                                            getUserInfoFromCacheOnly:senderUserInfo.userId];
                    if (userInfo) {
                        senderUserInfo.portraitUri = [userInfo.portraitUri copy];
                    }
                }
                [[RCUserInfoCacheManager sharedManager] updateUserInfo:senderUserInfo
                                                             forUserId:senderUserInfo.userId];
            }
        }
    }
    
    if ([messageContent isMemberOfClass:[RCUserInfoUpdateMessage class]]) {
        RCUserInfoUpdateMessage *userInfoMesasge = (RCUserInfoUpdateMessage *)messageContent;
        if ([userInfoMesasge.userInfoList count] > 0) {
            for (RCUserInfo *userInfo in userInfoMesasge.userInfoList) {
                if (![userInfo.userId isEqualToString:[RCIMClient sharedRCIMClient].currentUserInfo.userId] &&
                    ![[RCUserInfoCacheManager sharedManager] getUserInfo:userInfo.userId]) {
                    if (userInfo.name.length > 0 || userInfo.portraitUri.length > 0) {
                        [[RCUserInfoCacheManager sharedManager] updateUserInfo:userInfo forUserId:userInfo.userId];
                    }
                }
            }
        }
        return YES;
    }
    return NO;
}

- (BOOL)p_disbaleCustomMessageAlert:(RCMessage *)message left:(int)nLeft{
    //发出去的消息，不需要本地铃声和通知
    if (message.messageDirection == MessageDirection_SEND) {
        return YES;
    }

    if (0 != nLeft) {
        return YES;
    }
    
    BOOL isCustomMessageAlert = YES;
    // 不入库的不响铃，不本地通知提醒 此处不要return
    if (!([[message.content class] persistentFlag] & MessagePersistent_ISPERSISTED)) {
        isCustomMessageAlert = NO;
    }
    // 不识别消息的综合判断
    if (RCKitConfigCenter.message.showUnkownMessageNotificaiton && message.messageId > 0 && !message.content) {
        isCustomMessageAlert = YES;
    }
    
    if (!isCustomMessageAlert) {
        return YES;
    }
    
    return NO;
}

- (void)playSoundByMessageIfNeed:(RCMessage *)message {
    //在 IMKit 明确不支持超级群的情况下，超级群消息不做提醒
    if (ConversationType_ULTRAGROUP == message.conversationType) {
        return;
    }
    
    //APP在后台，不响铃
    if (RCSDKRunningMode_Foreground != [RCIMClient sharedRCIMClient].sdkRunningMode) {
        return;
    }
    //全局设置禁止响铃，不响铃
    if (RCKitConfigCenter.message.disableMessageAlertSound) {
        return;
    }
    //用户设置了免打扰，不响铃
    if ([self checkNoficationQuietStatus]) {
        return;
    }
    
    //获取接受到会话
    if ([[RongIMKitExtensionManager sharedManager] handleAlertForMessageReceived:message]) {
        return;
    }
    
    //业务设置onRCIMCustomAlertSound 返回YES，不响铃
    BOOL appConsumed = NO;
    for (id<RCIMReceiveMessageDelegate> delegate in [[RCKitListenerManager sharedManager] allReceiveMessageDelegates]) {
        if ([delegate respondsToSelector:@selector(onRCIMCustomAlertSound:)]) {
            if ([delegate onRCIMCustomAlertSound:message]) {
                appConsumed = YES;
                break;
            }
        }
    }
    if (appConsumed) {
        return;
    }
    
    //讨论组通知消息 不响铃
    if ([message.content isKindOfClass:[RCDiscussionNotificationMessage class]]) {
        return;
    }
    //消息设置为静默 不响铃
    if (message.messageConfig.disableNotification) {
        return;
    }
    
    
    if (message.content.mentionedInfo.isMentionedMe) {
        
        [[RCSystemSoundPlayer defaultPlayer] playSoundByMessage:message completeBlock:^(BOOL complete) {
            if (complete) {
                [self setExclusiveSoundPlayer];
            }
        }];
        
    } else {
        
        [[RCIMClient sharedRCIMClient] getConversationNotificationStatus:message.conversationType
                                                                targetId:message.targetId
                                                                 success:^(RCConversationNotificationStatus nStatus) {
            if (NOTIFY == nStatus) {
                [[RCSystemSoundPlayer defaultPlayer] playSoundByMessage:message
                                                          completeBlock:^(BOOL complete) {
                    if (complete) {
                        [self setExclusiveSoundPlayer];
                    }
                }];
            }
            
        } error:nil];
    }
}

- (void)onReceived:(RCMessage *)message left:(int)nLeft object:(id)object offline:(BOOL)offline hasPackage:(BOOL)hasPackage {
    for (id<RCIMReceiveMessageDelegate> delegate in [[RCKitListenerManager sharedManager] allReceiveMessageDelegates]) {
        if ([delegate respondsToSelector:@selector(onRCIMReceived:left:offline:hasPackage:)]) {
            [delegate onRCIMReceived:message left:nLeft offline:offline hasPackage:hasPackage];
        }
    }
}

- (void)setExclusiveSoundPlayer {
    if (RCKitConfigCenter.message.isExclusiveSoundPlayer || [RCKitUtility isAudioHolding] ||[RCKitUtility isCameraHolding]) {
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        [audioSession setCategory:AVAudioSessionCategoryAmbient error:nil];
        [audioSession setActive:YES error:nil];
    }else {
        //不独占音频 且 所有sdk都没有使用音频再归还给其他app。
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
    }
}

- (void)messageDidRecall:(RCMessage *)message {
    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchRecallMessageNotification
                                                        object:@(message.messageId)
                                                      userInfo:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchRecallMessageDetailNotification
                                                        object:message
                                                      userInfo:nil];
    for (id<RCIMReceiveMessageDelegate> delegate in [[RCKitListenerManager sharedManager] allReceiveMessageDelegates]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if ([delegate respondsToSelector:@selector(onRCIMMessageRecalled:)]) {
            [delegate onRCIMMessageRecalled:message.messageId];
        }
#pragma clang diagnostic pop
        
        if ([delegate respondsToSelector:@selector(messageDidRecall:)]) {
            [delegate messageDidRecall:message];
        }
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self postLocalNotificationIfNeed:message];
    });
}

- (void)onMessageReceiptResponse:(RCConversationType)conversationType
                        targetId:(NSString *)targetId
                      messageUId:(NSString *)messageUId
                      readerList:(NSDictionary *)userIdList {
    NSDictionary *statusDic = @{
        @"targetId" : targetId,
        @"conversationType" : @(conversationType),
        @"messageUId" : messageUId,
        @"readerList" : userIdList
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchMessageReceiptResponseNotification
                                                        object:statusDic
                                                      userInfo:nil];
}

- (void)onMessageReceiptRequest:(RCConversationType)conversationType
                       targetId:(NSString *)targetId
                     messageUId:(NSString *)messageUId {
    if (messageUId) {
        NSDictionary *statusDic =
            @{ @"targetId" : targetId,
               @"conversationType" : @(conversationType),
               @"messageUId" : messageUId };
        [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchMessageReceiptRequestNotification
                                                            object:statusDic
                                                          userInfo:nil];
    }
}

/**
 *  网络状态变化。
 *
 *  @param status 网络状态。
 */
- (void)onConnectionStatusChanged:(RCConnectionStatus)status {
    /*
     每次重连之后都需要清理免打扰的缓存数据, 防止以下问题:
     1. A登录设置免打扰后退出, B在同一个设备登陆后, 启用A的免打扰设置
     2. A在第一个手机登录, 进入后台, 又在另一台手机登陆后设置免打扰,此时, 重回第一部手机登录, 导致免打扰缓存数据不对的问题
     */
    if (status == ConnectionStatus_Connected) {
        [RCIMNotificationDataContext clean];
    }
    if (status == ConnectionStatus_KICKED_OFFLINE_BY_OTHER_CLIENT || status == ConnectionStatus_SignOut ||
        status == ConnectionStatus_TOKEN_INCORRECT) {
        self.hasNotifydExtensionModuleUserId = NO;
        [[RongIMKitExtensionManager sharedManager] didDisconnect];
    }

    if (ConnectionStatus_NETWORK_UNAVAILABLE != status && ConnectionStatus_UNKNOWN != status &&
        ConnectionStatus_Unconnected != status) {
        [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchConnectionStatusChangedNotification
                                                            object:[NSNumber numberWithInteger:status]];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(delayNotifyUnConnectedStatus) withObject:nil afterDelay:5];
        });
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (status == ConnectionStatus_Connected && !self.hasNotifydExtensionModuleUserId) {
            self.hasNotifydExtensionModuleUserId = YES;
            NSString *userId = [[RCIMClient sharedRCIMClient].currentUserInfo.userId copy];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[RongIMKitExtensionManager sharedManager] didConnect:userId];
            });
        }
    });
    for (id<RCIMConnectionStatusDelegate> delegate in [[RCKitListenerManager sharedManager] allConnectionStatusChangeDelegates]) {
        if ([delegate respondsToSelector:@selector(onRCIMConnectionStatusChanged:)]) {
            [delegate onRCIMConnectionStatusChanged:status];
        }
    }
    
}

- (void)setConnectionStatusDelegate:(id<RCIMConnectionStatusDelegate>)connectionStatusDelegate {
    [self addConnectionStatusDelegate:connectionStatusDelegate];
}

- (id<RCIMConnectionStatusDelegate>)connectionStatusDelegate {
    NSArray *connectDelegates =  [[RCKitListenerManager sharedManager] allConnectionStatusChangeDelegates];
        if (connectDelegates.count > 0) {
            return connectDelegates.firstObject;
        }
        return nil;
}

- (void)addConnectionStatusDelegate:(id<RCIMConnectionStatusDelegate>)delegate {
    [[RCKitListenerManager sharedManager] addConnectionStatusChangeDelegate:delegate];
}

- (void)removeConnectionStatusDelegate:(id<RCIMConnectionStatusDelegate>)delegate {
    [[RCKitListenerManager sharedManager] removeConnectionStatusChangeDelegate:delegate];
}

/*!
 获取当前SDK的连接状态

 @return 当前SDK的连接状态
 */
- (RCConnectionStatus)getConnectionStatus {
    return [[RCIMClient sharedRCIMClient] getConnectionStatus];
}

- (void)delayNotifyUnConnectedStatus {
    RCConnectionStatus status = [[RCIMClient sharedRCIMClient] getConnectionStatus];
    if (ConnectionStatus_NETWORK_UNAVAILABLE == status || ConnectionStatus_UNKNOWN == status ||
        ConnectionStatus_Unconnected == status) {
        [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchConnectionStatusChangedNotification
                                                            object:[NSNumber numberWithInteger:status]];
    }
}

#pragma mark - UserInfo&GroupInfo&GroupUserInfo
- (void)setEnablePersistentUserInfoCache:(BOOL)enablePersistentUserInfoCache {
    _enablePersistentUserInfoCache = enablePersistentUserInfoCache;
    NSString *userId = [[RCIMClient sharedRCIMClient].currentUserInfo.userId copy];
    if (enablePersistentUserInfoCache && userId) {
        [RCUserInfoCacheManager sharedManager].currentUserId = userId;
    }
}

- (RCUserInfo *)getUserInfoCache:(NSString *)userId {
    return [[RCUserInfoCacheManager sharedManager] getUserInfoFromCacheOnly:userId];
}

- (void)refreshUserInfoCache:(RCUserInfo *)userInfo withUserId:(NSString *)userId {
    //    [[RCUserInfoCacheManager sharedManager] clearUserInfoNetworkCacheOnly:userId];
    [[RCUserInfoCacheManager sharedManager] updateUserInfo:userInfo forUserId:userId];
}

- (void)clearUserInfoCache {
    [[RCUserInfoCacheManager sharedManager] clearAllUserInfo];
}

- (RCGroup *)getGroupInfoCache:(NSString *)groupId {
    return [[RCUserInfoCacheManager sharedManager] getGroupInfoFromCacheOnly:groupId];
}

- (void)refreshGroupInfoCache:(RCGroup *)groupInfo withGroupId:(NSString *)groupId {
    [[RCUserInfoCacheManager sharedManager] updateGroupInfo:groupInfo forGroupId:groupId];
}

- (void)clearGroupInfoCache {
    [[RCUserInfoCacheManager sharedManager] clearAllGroupInfo];
}

- (RCUserInfo *)getGroupUserInfoCache:(NSString *)userId withGroupId:(NSString *)groupId {
    return [[RCUserInfoCacheManager sharedManager] getUserInfoFromCacheOnly:userId inGroupId:groupId];
}

- (void)refreshGroupUserInfoCache:(RCUserInfo *)userInfo withUserId:(NSString *)userId withGroupId:(NSString *)groupId {
    [[RCUserInfoCacheManager sharedManager] updateUserInfo:userInfo forUserId:userId inGroup:groupId];
}

- (void)clearGroupUserInfoCache {
    [[RCUserInfoCacheManager sharedManager] clearAllGroupUserInfo];
}

- (RCMessage *)sendMessage:(RCConversationType)conversationType
                  targetId:(NSString *)targetId
                   content:(RCMessageContent *)content
               pushContent:(NSString *)pushContent
                  pushData:(NSString *)pushData
                   success:(void (^)(long messageId))successBlock
                     error:(void (^)(RCErrorCode nErrorCode, long messageId))errorBlock {
    if (targetId == nil || content == nil) {
        if (errorBlock) {
            errorBlock(INVALID_PARAMETER, 0);
        }
        NSLog(@"Parameters error");
        return nil;
    }
    content = [self beforeSendMessage:content];
    if (!content) {
        return nil;
    }

    [self attachCurrentUserInfo:content];

    RCMessage *message = [[RCMessage alloc] initWithType:conversationType targetId:targetId direction:MessageDirection_SEND content:content];
    
    // 查看是否拦截发送
    if ([self beforeInterceptSendMessage:message]) {
        return nil;
    }
    
    content = message.content;
    
    RCMessage *rcMessage = [[RCIMClient sharedRCIMClient] sendMessage:conversationType
                                                             targetId:targetId
                                                              content:content
                                                          pushContent:pushContent
                                                             pushData:pushData
                                                              success:^(long messageId) {
        [self postSendMessageSentNotification:targetId
                             conversationType:conversationType
                                    messageId:messageId
                                      content:content];
        [self sendMessageComplete:message status:0 messageId:messageId];
        if (successBlock) {
            successBlock(messageId);
        }
    } error:^(RCErrorCode nErrorCode, long messageId) {
        if (nErrorCode == RC_MSG_REPLACED_SENSITIVE_WORD) {
            [self postSendMessageSentNotification:targetId
                                 conversationType:conversationType
                                        messageId:messageId
                                          content:content];
            [self sendMessageComplete:message status:0 messageId:messageId];
            if (successBlock) {
                successBlock(messageId);
            }
        } else {
            [self postSendMessageErrorNotification:targetId
                                  conversationType:conversationType
                                         messageId:messageId
                                             error:nErrorCode
                                           content:content];
            [self sendMessageComplete:message status:nErrorCode messageId:messageId];
            if (errorBlock) {
                errorBlock(nErrorCode, messageId);
            }
        }
    }];

    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                        object:rcMessage
                                                      userInfo:nil];
    return rcMessage;
}

- (RCMessage *)sendMessage:(RCMessage *)message
               pushContent:(NSString *)pushContent
                  pushData:(NSString *)pushData
              successBlock:(void (^)(RCMessage *successMessage))successBlock
                errorBlock:(void (^)(RCErrorCode nErrorCode, RCMessage *errorMessage))errorBlock {
    if (message.targetId == nil || message.content == nil) {
        if (errorBlock) {
            errorBlock(INVALID_PARAMETER, message);
        }
        NSLog(@"Parameters error");
        return nil;
    }
    message.content = [self beforeSendMessage:message.content];
    if (!message.content) {
        return nil;
    }

    [self attachCurrentUserInfo:message.content];
    
    // 查看是否拦截发送
    if ([self beforeInterceptSendMessage:message]) {
        return nil;
    }
    
    RCMessage *rcMessage = [[RCIMClient sharedRCIMClient] sendMessage:message pushContent:pushContent pushData:pushData successBlock:^(RCMessage *successMessage) {
        [self postSendMessageSentNotification:successMessage.targetId
                             conversationType:successMessage.conversationType
                                    messageId:successMessage.messageId
                                      content:successMessage.content];
        [self sendMessageComplete:successMessage status:0];
        if (successBlock) {
            successBlock(successMessage);
        }
    } errorBlock:^(RCErrorCode nErrorCode, RCMessage *errorMessage) {
        if (nErrorCode == RC_MSG_REPLACED_SENSITIVE_WORD) {
            [self postSendMessageSentNotification:errorMessage.targetId
                                 conversationType:errorMessage.conversationType
                                        messageId:errorMessage.messageId
                                          content:errorMessage.content];
            [self sendMessageComplete:errorMessage status:0];
            if (successBlock) {
                successBlock(errorMessage);
            }
        } else {
            [self postSendMessageErrorNotification:errorMessage.targetId
                                  conversationType:errorMessage.conversationType
                                         messageId:errorMessage.messageId
                                             error:nErrorCode
                                           content:errorMessage.content];
            [self sendMessageComplete:errorMessage status:nErrorCode];
            if (errorBlock) {
                errorBlock(nErrorCode, errorMessage);
            }
        }
    }];
    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                        object:rcMessage
                                                      userInfo:nil];
    return rcMessage;
}

- (RCMessage *)sendDirectionalMessage:(RCConversationType)conversationType
                             targetId:(NSString *)targetId
                         toUserIdList:(NSArray *)userIdList
                              content:(RCMessageContent *)content
                          pushContent:(NSString *)pushContent
                             pushData:(NSString *)pushData
                              success:(void (^)(long messageId))successBlock
                                error:(void (^)(RCErrorCode nErrorCode, long messageId))errorBlock {
    if (targetId == nil || content == nil) {
        if (errorBlock) {
            errorBlock(INVALID_PARAMETER, 0);
        }
        NSLog(@"Parameters error");
        return nil;
    }
    content = [self beforeSendMessage:content];
    if (!content) {
        return nil;
    }
    [self attachCurrentUserInfo:content];
    RCMessage *message = [[RCMessage alloc] initWithType:conversationType targetId:targetId direction:MessageDirection_SEND content:content];
    
    // 查看是否拦截发送
    if ([self beforeInterceptSendMessage:message]) {
        return nil;
    }
    content = message.content;
    RCMessage *rcMessage = [[RCIMClient sharedRCIMClient] sendDirectionalMessage:conversationType
    targetId:targetId
    toUserIdList:userIdList
    content:content
    pushContent:pushContent
    pushData:pushData
    success:^(long messageId) {
        [self postSendMessageSentNotification:targetId
                             conversationType:conversationType
                                    messageId:messageId
                                      content:content];
        [self sendMessageComplete:message status:0 messageId:messageId];
        if (successBlock) {
            successBlock(messageId);
        }
    }
    error:^(RCErrorCode nErrorCode, long messageId) {
        if (nErrorCode == RC_MSG_REPLACED_SENSITIVE_WORD) {
            [self postSendMessageSentNotification:targetId
                                 conversationType:conversationType
                                        messageId:messageId
                                          content:content];
            [self sendMessageComplete:message status:0 messageId:messageId];
            if (successBlock) {
                successBlock(messageId);
            }
        } else {
            [self postSendMessageErrorNotification:targetId
                                  conversationType:conversationType
                                         messageId:messageId
                                             error:nErrorCode
                                           content:content];
            [self sendMessageComplete:message status:nErrorCode messageId:messageId];
            if (errorBlock) {
                errorBlock(nErrorCode, messageId);
            }
        }
    }];

    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                        object:rcMessage
                                                      userInfo:nil];
    return rcMessage;
}

- (void)downloadMediaMessage:(long)messageId
                    progress:(void (^)(int progress))progressBlock
                     success:(void (^)(NSString *mediaPath))successBlock
                       error:(void (^)(RCErrorCode errorCode))errorBlock
                      cancel:(void (^)(void))cancelBlock {
    if ([self.downloadingMeidaMessageIds containsObject:@(messageId)]) {
        return;
    }
    
    [self addMeidaMessageId:@(messageId)];

    [[RCIMClient sharedRCIMClient] downloadMediaMessage:messageId
        progress:^(int progress) {
            NSDictionary *statusDic =
                @{ @"messageId" : @(messageId),
                   @"type" : @"progress",
                   @"progress" : @(progress) };
            [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchDownloadMediaNotification
                                                                object:nil
                                                              userInfo:statusDic];
            if (progressBlock) {
                progressBlock(progress);
            }
        }
        success:^(NSString *mediaPath) {
            [self removeMeidaMessageId:@(messageId)];

            NSDictionary *statusDic = @{ @"messageId" : @(messageId), @"type" : @"success", @"mediaPath" : mediaPath };
            [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchDownloadMediaNotification
                                                                object:nil
                                                              userInfo:statusDic];
            if (successBlock) {
                successBlock(mediaPath);
            }
        }
        error:^(RCErrorCode errorCode) {
            [self removeMeidaMessageId:@(messageId)];

            NSDictionary *statusDic = @{ @"messageId" : @(messageId), @"type" : @"error", @"errorCode" : @(errorCode) };
            [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchDownloadMediaNotification
                                                                object:nil
                                                              userInfo:statusDic];
            if (errorBlock) {
                errorBlock(errorCode);
            }
        }
        cancel:^{
            [self removeMeidaMessageId:@(messageId)];

            NSDictionary *statusDic = @{ @"messageId" : @(messageId), @"type" : @"cancel" };
            [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchDownloadMediaNotification
                                                                object:nil
                                                              userInfo:statusDic];
            if (cancelBlock) {
                cancelBlock();
            }
        }];
}

- (void)addMeidaMessageId:(NSNumber *)messageId {
    if (self.downloadingMeidaMessageIds.count <= 0) {
        self.downloadingMeidaMessageIds = [@[messageId] mutableCopy];
        return;
    }
    
    NSMutableArray *msgIds = [NSMutableArray arrayWithArray:self.downloadingMeidaMessageIds];
    [msgIds addObject:messageId];
    self.downloadingMeidaMessageIds = [msgIds copy];
}

- (void)removeMeidaMessageId:(NSNumber *)messageId {
    if (self.downloadingMeidaMessageIds.count <= 0) {
        return;
    }
    
    NSMutableArray *msgIds = [NSMutableArray arrayWithArray:self.downloadingMeidaMessageIds];
    [msgIds enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if ([obj isEqualToNumber:messageId]) {
            [msgIds removeObject:obj];
            *stop = YES;
        }
    }];
    self.downloadingMeidaMessageIds = [msgIds copy];
}

- (BOOL)cancelDownloadMediaMessage:(long)messageId {
    return [[RCIMClient sharedRCIMClient] cancelDownloadMediaMessage:messageId];
}

- (RCMessage *)sendMediaMessage:(RCConversationType)conversationType
                       targetId:(NSString *)targetId
                        content:(RCMessageContent *)content
                    pushContent:(NSString *)pushContent
                       pushData:(NSString *)pushData
                       progress:(void (^)(int progress, long messageId))progressBlock
                        success:(void (^)(long messageId))successBlock
                          error:(void (^)(RCErrorCode errorCode, long messageId))errorBlock
                         cancel:(void (^)(long messageId))cancelBlock {
    if (targetId == nil || content == nil) {
        if (errorBlock) {
            errorBlock(INVALID_PARAMETER, 0);
        }
        NSLog(@"Parameters error");
        return nil;
    }
    content = [self beforeSendMessage:content];
    if (!content) {
        return nil;
    }
    
    [self attachCurrentUserInfo:content];
    
    RCMessage *message = [[RCMessage alloc] initWithType:conversationType targetId:targetId direction:MessageDirection_SEND content:content];
    
    // 查看是否拦截发送
    if ([self beforeInterceptSendMessage:message]) {
        return nil;
    }
    content = message.content;
    RCMessage *rcMessage = [[RCIMClient sharedRCIMClient] sendMediaMessage:conversationType
    targetId:targetId
    content:content
    pushContent:pushContent
    pushData:pushData
    progress:^(int progress, long messageId) {
        NSDictionary *statusDic = @{
            @"targetId" : targetId,
            @"conversationType" : @(conversationType),
            @"messageId" : @(messageId),
            @"sentStatus" : @(SentStatus_SENDING),
            @"progress" : @(progress)
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                            object:nil
                                                          userInfo:statusDic];
        if (progressBlock) {
            progressBlock(progress, messageId);
        }
    }
    success:^(long messageId) {
        [self postSendMessageSentNotification:targetId
                             conversationType:conversationType
                                    messageId:messageId
                                      content:content];
        [self sendMessageComplete:message status:0 messageId:messageId];
        if (successBlock) {
            successBlock(messageId);
        }
    }
    error:^(RCErrorCode errorCode, long messageId) {
        [self postSendMessageErrorNotification:targetId
                              conversationType:conversationType
                                     messageId:messageId
                                         error:errorCode
                                       content:content];
        [self sendMessageComplete:message status:errorCode messageId:messageId];
        if (errorBlock) {
            errorBlock(errorCode, messageId);
        }
    }
    cancel:^(long messageId) {
        NSDictionary *statusDic = @{
            @"targetId" : targetId,
            @"conversationType" : @(conversationType),
            @"messageId" : @(messageId),
            @"sentStatus" : @(SentStatus_CANCELED),
            @"content" : content
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                            object:nil
                                                          userInfo:statusDic];
        if (cancelBlock) {
            cancelBlock(messageId);
        }
    }];

    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                        object:rcMessage
                                                      userInfo:nil];

    return rcMessage;
}

- (RCMessage *)sendMediaMessage:(RCMessage *)message
                    pushContent:(NSString *)pushContent
                       pushData:(NSString *)pushData
                       progress:(void (^)(int progress, RCMessage *progressMessage))progressBlock
                   successBlock:(void (^)(RCMessage *successMessage))successBlock
                     errorBlock:(void (^)(RCErrorCode nErrorCode, RCMessage *errorMessage))errorBlock
                         cancel:(void (^)(RCMessage *cancelMessage))cancelBlock {
    if (message.targetId == nil || message.content == nil) {
        if (errorBlock) {
            errorBlock(INVALID_PARAMETER, message);
        }
        NSLog(@"Parameters error");
        return nil;
    }
    message.content = [self beforeSendMessage:message.content];
    if (!message.content) {
        return nil;
    }
    [self attachCurrentUserInfo:message.content];
    
    // 查看是否拦截发送
    if ([self beforeInterceptSendMessage:message]) {
        return nil;
    }

    RCMessage *rcMessage = [[RCIMClient sharedRCIMClient] sendMediaMessage:message pushContent:pushContent pushData:pushData progress:^(int progress, RCMessage *progressMessage) {
        NSDictionary *statusDic = @{
            @"targetId" : progressMessage.targetId,
            @"conversationType" : @(progressMessage.conversationType),
            @"messageId" : @(progressMessage.messageId),
            @"sentStatus" : @(SentStatus_SENDING),
            @"progress" : @(progress)
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                            object:nil
                                                          userInfo:statusDic];
        if (progressBlock) {
            progressBlock(progress, progressMessage);
        }
    } successBlock:^(RCMessage *successMessage) {
        [self postSendMessageSentNotification:successMessage.targetId
                             conversationType:successMessage.conversationType
                                    messageId:successMessage.messageId
                                      content:successMessage.content];
        [self sendMessageComplete:successMessage status:0];
        if (successBlock) {
            successBlock(successMessage);
        }
    } errorBlock:^(RCErrorCode nErrorCode, RCMessage *errorMessage) {
        [self postSendMessageErrorNotification:errorMessage.targetId
                              conversationType:errorMessage.conversationType
                                     messageId:errorMessage.messageId
                                         error:nErrorCode
                                       content:errorMessage.content];
        [self sendMessageComplete:errorMessage status:nErrorCode];
        if (errorBlock) {
            errorBlock(nErrorCode, errorMessage);
        }
    }  cancel:^(RCMessage *cancelMessage) {
        NSDictionary *statusDic = @{
            @"targetId" : cancelMessage.targetId,
            @"conversationType" : @(cancelMessage.conversationType),
            @"messageId" : @(cancelMessage.messageId),
            @"sentStatus" : @(SentStatus_CANCELED),
            @"content" : cancelMessage.content
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                            object:nil
                                                          userInfo:statusDic];
        if (cancelBlock) {
            cancelBlock(cancelMessage);
        }
    }];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                        object:rcMessage
                                                      userInfo:nil];
    return rcMessage;
}

- (RCMessage *)sendMediaMessage:(RCMessage *)message
                    pushContent:(NSString *)pushContent
                       pushData:(NSString *)pushData
                  uploadPrepare:(void (^)(RCUploadMediaStatusListener *uploadListener))uploadPrepareBlock
                       progress:(void (^)(int progress, long messageId))progressBlock
                   successBlock:(void (^)(long messageId))successBlock
                     errorBlock:(void (^)(RCErrorCode errorCode, long messageId))errorBlock
                         cancel:(void (^)(long messageId))cancelBlock {
    RCConversationType conversationType = message.conversationType;
    NSString *targetId = [message.targetId copy];
    RCMessage *rcMessage = [[RCIMClient sharedRCIMClient] sendMediaMessage:conversationType targetId:targetId content:message.content pushContent:pushContent pushData:pushData uploadPrepare:uploadPrepareBlock progress:^(int progress, long messageId) {
        NSDictionary *statusDic = @{
            @"targetId" : targetId,
            @"conversationType" : @(conversationType),
            @"messageId" : @(messageId),
            @"sentStatus" : @(SentStatus_SENDING),
            @"progress" : @(progress)
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification object:nil userInfo:statusDic];
        if (progressBlock) {
            progressBlock(progress, messageId);
        }
    } success:^(long messageId) {
        [self postSendMessageSentNotification:targetId
                             conversationType:conversationType
                                    messageId:messageId
                                      content:message.content];
        [self sendMessageComplete:message status:0 messageId:messageId];

        if (successBlock) {
            successBlock(messageId);
        }
    } error:^(RCErrorCode errorCode, long messageId) {
        [self postSendMessageErrorNotification:targetId
                              conversationType:conversationType
                                     messageId:messageId
                                         error:errorCode
                                       content:message.content];
        [self sendMessageComplete:message status:errorCode messageId:messageId];
        if (errorBlock) {
            errorBlock(errorCode, messageId);
        }
    } cancel:^(long messageId) {
        NSDictionary *statusDic = @{
            @"targetId" : targetId,
            @"conversationType" : @(conversationType),
            @"messageId" : @(messageId),
            @"sentStatus" : @(SentStatus_CANCELED),
            @"content" : message.content
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification object:nil userInfo:statusDic];
        if (cancelBlock) {
            cancelBlock(messageId);
        }
    }];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification object:rcMessage userInfo:nil];
    return rcMessage;
}


- (BOOL)cancelSendMediaMessage:(long)messageId {
    BOOL isCanceled = [[RCIMClient sharedRCIMClient] cancelSendMediaMessage:messageId];
    if ([[RCResendManager sharedManager] needResend:messageId]) {
        [[RCResendManager sharedManager] removeResendMessage:messageId];
    }
    return isCanceled;
}

- (RCMessageContent *)beforeSendMessage:(RCMessageContent *)content {
    if ([self.sendMessageDelegate respondsToSelector:@selector(willSendIMMessage:)]) {
        content = [self.sendMessageDelegate willSendIMMessage:content];
    }
    return content;
}

- (BOOL)beforeInterceptSendMessage:(RCMessage *)message {
    if ([self.messageInterceptor respondsToSelector:@selector(interceptWillSendMessage:)]) {
        return [self.messageInterceptor interceptWillSendMessage:message];
    }
    return NO;
}


- (void)postSendMessageSentNotification:(NSString *)targetId
                       conversationType:(RCConversationType)conversationType
                              messageId:(long)messageId
                                content:(RCMessageContent *)content {
    NSDictionary *statusDic = @{
        @"targetId" : targetId,
        @"conversationType" : @(conversationType),
        @"messageId" : @(messageId),
        @"sentStatus" : @(SentStatus_SENT),
        @"content" : content
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                        object:nil
                                                      userInfo:statusDic];
}

- (void)postSendMessageErrorNotification:(NSString *)targetId
                        conversationType:(RCConversationType)conversationType
                               messageId:(long)messageId
                                   error:(RCErrorCode)nErrorCode
                                 content:(RCMessageContent *)content {
    [[RCResendManager sharedManager] addResendMessageIfNeed:messageId error:nErrorCode];
    NSDictionary *statusDic = @{
        @"targetId" : targetId,
        @"conversationType" : @(conversationType),
        @"messageId" : @(messageId),
        @"sentStatus" : @(SentStatus_FAILED),
        @"error" : @(nErrorCode),
        @"content" : content
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitSendingMessageNotification
                                                        object:nil
                                                      userInfo:statusDic];
}

- (void)sendMessageComplete:(RCMessage *)message status:(NSInteger)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.sendMessageDelegate respondsToSelector:@selector(didSendIMMessage:status:)]) {
            [self.sendMessageDelegate didSendIMMessage:message.content status:status];
        }
        
        if ([self.messageInterceptor respondsToSelector:@selector(interceptDidSendMessage:)]) {
            [self.messageInterceptor interceptDidSendMessage:message];
        }
    });
}

- (void)sendMessageComplete:(RCMessage *)incompleteMessage status:(NSInteger)status messageId:(long)messageId {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.sendMessageDelegate respondsToSelector:@selector(didSendIMMessage:status:)]) {
            [self.sendMessageDelegate didSendIMMessage:incompleteMessage.content status:status];
        }
    });
    
    if ([self.messageInterceptor respondsToSelector:@selector(interceptDidSendMessage:)]) {
        // 此处需要回调完整 RCMessage, 只能读取db
        RCMessage *fullMessage = [[RCIMClient sharedRCIMClient] getMessage:messageId];
        if (!fullMessage) {
            fullMessage = incompleteMessage;
            fullMessage.messageId = messageId;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.messageInterceptor interceptDidSendMessage:fullMessage];
        });
    }
}

#pragma mark - 消息阅后即焚

- (void)onMessageDestructing:(RCMessage *)message remainDuration:(long long)remainDuration {
    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitMessageDestructingNotification
                                                        object:nil
                                                      userInfo:@{
                                                          @"message" : message,
                                                          @"remainDuration" : @(remainDuration)
                                                      }];
}

#pragma mark - Discussion
- (void)sendUserInfoUpdateMessageForDiscussion:(NSString *)discussionId userIdList:(NSArray *)userIdList {
    NSMutableArray *userInfoList = [[NSMutableArray alloc] init];
    for (NSString *userId in userIdList) {
        RCUserInfo *cacheUserInfo = [[RCUserInfoCacheManager sharedManager] getUserInfo:userId];
        if (cacheUserInfo.name.length > 0 || cacheUserInfo.portraitUri.length > 0) {
            [userInfoList addObject:cacheUserInfo];
        }
    }
    RCUserInfoUpdateMessage *message = [[RCUserInfoUpdateMessage alloc] initWithUserInfoList:userInfoList];
    [self attachCurrentUserInfo:message];

    [[RCIMClient sharedRCIMClient] sendMessage:ConversationType_DISCUSSION
        targetId:discussionId
        content:message
        pushContent:nil
        pushData:nil
        success:^(long messageId) {

        }
        error:^(RCErrorCode nErrorCode, long messageId){

        }];
}

- (void)createDiscussion:(NSString *)name
              userIdList:(NSArray *)userIdList
                 success:(void (^)(RCDiscussion *discussion))successBlock
                   error:(void (^)(RCErrorCode status))errorBlock {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[RCDiscussionClient sharedDiscussionClient] createDiscussion:name
        userIdList:userIdList
        success:^(RCDiscussion *discussion) {
            [self sendUserInfoUpdateMessageForDiscussion:discussion.discussionId userIdList:discussion.memberIdList];
            if (successBlock) {
                successBlock(discussion);
            }
        }
        error:^(RCErrorCode status) {
            if (errorBlock) {
                errorBlock(status);
            }
        }];
#pragma clang diagnostic pop
}

- (void)addMemberToDiscussion:(NSString *)discussionId
                   userIdList:(NSArray *)userIdList
                      success:(void (^)(RCDiscussion *discussion))successBlock
                        error:(void (^)(RCErrorCode status))errorBlock {
    [self sendUserInfoUpdateMessageForDiscussion:discussionId userIdList:userIdList];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[RCDiscussionClient sharedDiscussionClient] addMemberToDiscussion:discussionId
        userIdList:userIdList
        success:^(RCDiscussion *discussion) {
            if (successBlock) {
                successBlock(discussion);
            }
        }
        error:^(RCErrorCode status) {
            if (errorBlock) {
                errorBlock(status);
            }
        }];
#pragma clang diagnostic pop
}

- (void)removeMemberFromDiscussion:(NSString *)discussionId
                            userId:(NSString *)userId
                           success:(void (^)(RCDiscussion *discussion))successBlock
                             error:(void (^)(RCErrorCode status))errorBlock {
    [self sendUserInfoUpdateMessageForDiscussion:discussionId userIdList:@[ userId ]];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[RCDiscussionClient sharedDiscussionClient] removeMemberFromDiscussion:discussionId
        userId:userId
        success:^(RCDiscussion *discussion) {
            if (successBlock) {
                successBlock(discussion);
            }
        }
        error:^(RCErrorCode status) {
            if (errorBlock) {
                errorBlock(status);
            }
        }];
#pragma clang diagnostic pop
}

- (void)quitDiscussion:(NSString *)discussionId
               success:(void (^)(RCDiscussion *discussion))successBlock
                 error:(void (^)(RCErrorCode status))errorBlock {
    [self sendUserInfoUpdateMessageForDiscussion:discussionId userIdList:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[RCDiscussionClient sharedDiscussionClient] quitDiscussion:discussionId
        success:^(RCDiscussion *discussion) {
            if (successBlock) {
                successBlock(discussion);
            }
        }
        error:^(RCErrorCode status) {
            if (errorBlock) {
                errorBlock(status);
            }
        }];
#pragma clang diagnostic pop
}

- (void)getDiscussion:(NSString *)discussionId
              success:(void (^)(RCDiscussion *discussion))successBlock
                error:(void (^)(RCErrorCode status))errorBlock {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[RCDiscussionClient sharedDiscussionClient] getDiscussion:discussionId
        success:^(RCDiscussion *discussion) {
            if (successBlock) {
                successBlock(discussion);
            }
        }
        error:^(RCErrorCode status) {
            if (errorBlock) {
                errorBlock(status);
            }
        }];
#pragma clang diagnostic pop
}

- (void)setDiscussionName:(NSString *)discussionId
                     name:(NSString *)discussionName
                  success:(void (^)(void))successBlock
                    error:(void (^)(RCErrorCode status))errorBlock {
    [self sendUserInfoUpdateMessageForDiscussion:discussionId userIdList:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[RCDiscussionClient sharedDiscussionClient] setDiscussionName:discussionId
        name:discussionName
        success:^{
            if (successBlock) {
                successBlock();
            }
        }
        error:^(RCErrorCode status) {
            if (errorBlock) {
                errorBlock(status);
            }
        }];
#pragma clang diagnostic pop
}

- (void)setDiscussionInviteStatus:(NSString *)discussionId
                           isOpen:(BOOL)isOpen
                          success:(void (^)(void))successBlock
                            error:(void (^)(RCErrorCode status))errorBlock {
    [self sendUserInfoUpdateMessageForDiscussion:discussionId userIdList:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[RCDiscussionClient sharedDiscussionClient] setDiscussionInviteStatus:discussionId
        isOpen:isOpen
        success:^{
            if (successBlock) {
                successBlock();
            }
        }
        error:^(RCErrorCode status) {
            if (errorBlock) {
                errorBlock(status);
            }
        }];
#pragma clang diagnostic pop
}

- (void)setScheme:(NSString *)scheme forExtensionModule:(NSString *)moduleName {
    [[RongIMKitExtensionManager sharedManager] setScheme:scheme forModule:moduleName];
}

- (BOOL)openExtensionModuleUrl:(NSURL *)url {
    return [[RongIMKitExtensionManager sharedManager] onOpenUrl:url];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)attachCurrentUserInfo:(RCMessageContent *)content {
    if ([RCIM sharedRCIM].enableMessageAttachUserInfo && !content.senderUserInfo) {
        content.senderUserInfo = [[RCUserInfo alloc] init];
        content.senderUserInfo.userId = [RCIMClient sharedRCIMClient].currentUserInfo.userId;
        content.senderUserInfo.name = [RCIMClient sharedRCIMClient].currentUserInfo.name;
        if ([RCUtilities isLocalPath:[RCIMClient sharedRCIMClient].currentUserInfo.portraitUri]) {
            content.senderUserInfo.portraitUri = nil;
        } else {
            content.senderUserInfo.portraitUri = [RCIMClient sharedRCIMClient].currentUserInfo.portraitUri;
        }
        content.senderUserInfo.extra = [RCIMClient sharedRCIMClient].currentUserInfo.extra;
    }
}


- (void)conversationStatusDidChange:(NSArray<RCConversationStatusInfo *> *)conversationStatusInfos {
    [[NSNotificationCenter defaultCenter] postNotificationName:RCKitDispatchConversationStatusChangeNotification
                                                        object:conversationStatusInfos
                                                      userInfo:nil];
}

+ (NSString *)getVersion {
    return RCIMKitVersion;
}

@end
