//
//  MXWebviewBridge.m
//  MXWebviewDemo
//
//  Created by 罗贤明 on 16/6/9.
//  Copyright © 2016年 罗贤明. All rights reserved.
//

#import "MXWebviewBridge.h"
#import "MXWebviewContext.h"
#import "MXWebviewPlugin.h"
#import "UIWebView+MXBridge.h"
/**
 * JS可以直接调用的 Native的方法。
 */
@protocol MXNativeBridgeExport <JSExport>

/**
 *  打日志，带日志等级
 */
- (void)loggerWithLevel;

/**
 *  异步调用函数
 */
- (void)callAsyn;


/**
 *  同步调用函数
 */
- (JSValue *)callSync;

@end


@interface MXWebviewBridge ()<MXNativeBridgeExport>

/**
 *  webview持有一个bridge， bridge持有插件。这里是持有插件队列的地方。每个插件在一个webview中只会存在一个。
 */
@property (nonatomic,strong) NSMutableDictionary<NSString *,MXWebviewPlugin *> *pluginDictionarys;


@end


@implementation MXWebviewBridge

- (instancetype)initWithWebview:(UIWebView *)webview {
    if (self = [super init]) {
        _webview = webview;
        _pluginDictionarys = [[NSMutableDictionary alloc] init];
    }
    return self;
}

/**
 *  初始化JS环境，注入js。
 */
- (void)setupJSContext {
    JSContext *context = [_webview valueForKeyPath: @"documentView.webView.mainFrame.javaScriptContext"];
    if (context == _context) {
        return;
    }
    _context = context;
    if ([_context respondsToSelector:@selector(evaluateScript:withSourceURL:)]) {
        [_context evaluateScript:[MXWebviewContext shareContext].bridgeJS withSourceURL:[MXWebviewContext shareContext].bridgeJSURL];
    } else {
        [_context evaluateScript:[MXWebviewContext shareContext].bridgeJS];
    }
    _jsBridge = [_context[@"mxbridge"] valueForProperty:@"JSbridgeForOC"];
    // 这里实际上有一个引用的环，暂时通过clean方法来清除这个环。
    [_context[@"mxbridge"] setValue:self forProperty:@"OCBridgeForJS"];
    if ([MXWebviewContext shareContext].appName) {
        [_context[@"mxbridge"] setValue:[MXWebviewContext shareContext].appName forProperty:@"appName"];
    }
    if ([MXWebviewContext shareContext].appVersion) {
        [_context[@"mxbridge"] setValue:[MXWebviewContext shareContext].appVersion forProperty:@"appVersion"];
    }
    if ([MXWebviewContext shareContext].osType) {
        [_context[@"mxbridge"] setValue:[MXWebviewContext shareContext].osType forProperty:@"osType"];
    }
    if ([MXWebviewContext shareContext].osVersion) {
        [_context[@"mxbridge"] setValue:[MXWebviewContext shareContext].osVersion forProperty:@"osVersion"];
    }
    // 加载完成，才发送消息bridgeready。
    if ([_context respondsToSelector:@selector(evaluateScript:withSourceURL:)]) {
        [_context evaluateScript:@"if (document.addEventListener) {var readyEvent = document.createEvent('UIEvents');window.mxbridge.isReady = true;readyEvent.initEvent('bridgeReady', false, false);document.dispatchEvent(readyEvent);}" withSourceURL:[MXWebviewContext shareContext].bridgeJSURL];
    } else {
        [_context evaluateScript:@"if (document.addEventListener) {var readyEvent = document.createEvent('UIEvents');window.mxbridge.isReady = true;readyEvent.initEvent('bridgeReady', false, false);document.dispatchEvent(readyEvent);}"];
    }
}

- (void)cleanJSContext {
    [_context[@"mxbridge"] setValue:nil forProperty:@"OCBridgeForJS"];
    _jsBridge = nil;
}

- (UIViewController *)containerVC {
    if (!_containerVC) {
        UIResponder *next = _webview;
        while (next) {
            if([next isKindOfClass: [UIViewController class]] ){
                break;
            }
            next = next.nextResponder;
        }
        if (nil != next && [next isKindOfClass: [UIViewController class]]) {
            _containerVC = (UIViewController *)next;
        }else {
            NSLog(@"未设置containerVC，且未将webview放置在Controller中，而想要使用ContainerVC,失败。");
        }
    }
    return _containerVC;
}

#pragma mark - callforJS

- (void)loggerWithLevel {
    NSArray *args = [JSContext currentArguments];
    id log = args[0];
    NSInteger level = [args[1] toInt32];
    [MXWebviewContext shareContext].loggerBlock(log,level);
}


- (void)callAsyn {
    NSDictionary *jscall = [[JSContext currentArguments][0] toDictionary];
    __weak MXWebviewBridge *wself = self;
    //    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    dispatch_async(dispatch_get_main_queue(), ^{ // 在主线程中执行。
        MXMethodInvocation *invocation = [[MXMethodInvocation alloc] initWithJSCall:jscall];
        if (invocation == nil) {
            NSDictionary *error = @{@"errorCode":MXBridge_ReturnCode_PLUGIN_INIT_FAILED,@"errorMsg":@"传递参数错误，无法调用函数！"};
            NSLog(@"异步调用 ，失败 %@",error);
        }
        MXWebviewPlugin *plugin = _pluginDictionarys[invocation.pluginName];
        if (!plugin) {
            Class cls = [MXWebviewContext shareContext].plugins[invocation.pluginName];
            if (cls == NULL) {
                NSDictionary *error = @{@"errorCode":MXBridge_ReturnCode_PLUGIN_NOT_FOUND,@"errorMsg":[NSString stringWithFormat:@"插件 %@ 并不存在 ",invocation.pluginName]};
                [wself callBackSuccess:NO withDictionary:error toInvocation:invocation];
            }
            plugin = [[cls alloc] initWithBridge:self];
            _pluginDictionarys[invocation.pluginName] = plugin;
        }
        // 调用 插件中相应方法
        SEL selector = NSSelectorFromString(invocation.functionName);
        if (![plugin respondsToSelector:selector]) {
            selector = NSSelectorFromString([invocation.functionName stringByAppendingString:@":"]);
            if (![plugin respondsToSelector:selector]) {
                NSDictionary *error = @{@"errorCode":MXBridge_ReturnCode_METHOD_NOT_FOUND_EXCEPTION,@"errorMsg":[NSString stringWithFormat:@"插件对应函数 %@ 并不存在 ",invocation.functionName]};
                [wself callBackSuccess:NO withDictionary:error toInvocation:invocation];
            }
        }
        // 调用插件
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [plugin performSelector:selector withObject:invocation];
#pragma clang diagnostic pop
    });
}


- (JSValue *)callSync {
    NSDictionary *jscall = [[JSContext currentArguments][0] toDictionary];
    MXMethodInvocation *invocation = [[MXMethodInvocation alloc] initWithJSCall:jscall];
    if (invocation == nil) {
        NSDictionary *error = @{@"errorCode":MXBridge_ReturnCode_PLUGIN_INIT_FAILED,@"errorMsg":@"传递参数错误，无法调用函数！"};
        return [JSValue valueWithObject:error inContext:_context];
    }
    MXWebviewPlugin *plugin = _pluginDictionarys[invocation.pluginName];
    if (!plugin) {
        Class cls = [MXWebviewContext shareContext].plugins[invocation.pluginName];
        if (cls == NULL) {
            NSDictionary *error = @{@"errorCode":MXBridge_ReturnCode_PLUGIN_NOT_FOUND,@"errorMsg":[NSString stringWithFormat:@"插件 %@ 并不存在 ",invocation.pluginName]};
            return [JSValue valueWithObject:error inContext:_context];
        }
        plugin = [[cls alloc] initWithBridge:self];
        _pluginDictionarys[invocation.pluginName] = plugin;
    }
    // 调用 插件中相应方法
    SEL selector = NSSelectorFromString(invocation.functionName);
    if (![plugin respondsToSelector:selector]) {
        selector = NSSelectorFromString([invocation.functionName stringByAppendingString:@":"]);
        if (![plugin respondsToSelector:selector]) {
            NSDictionary *error = @{@"errorCode":MXBridge_ReturnCode_METHOD_NOT_FOUND_EXCEPTION,@"errorMsg":[NSString stringWithFormat:@"插件对应函数 %@ 并不存在 ",invocation.functionName]};
            return [JSValue valueWithObject:error inContext:_context];
        }
    }
    // 调用插件
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSDictionary *retJson = [plugin performSelector:selector withObject:invocation];
#pragma clang diagnostic pop
    if ([retJson isKindOfClass:[NSDictionary class]]) {
        JSValue *retJSValue = [JSValue valueWithObject:retJson inContext:_context];
        return retJSValue;
    }
    return [JSValue valueWithNullInContext:_context];
}


#pragma mark - callForNative



- (void)callBackSuccess:(BOOL)success withDictionary:(NSDictionary *)dict toInvocation:(MXMethodInvocation *)invocation {
    UIWebView *webview = _webview;
    if (webview && invocation.invocationID) {
        // 只要检测webview是否还在，就可以了
        // 回调JS。
        NSNumber *status = success ? MXBridge_ReturnCode_OK : MXBridge_ReturnCode_FAILED;
        NSArray *callBackParams = dict ? @[invocation.invocationID,status,dict] : @[invocation.invocationID,status];
        dispatch_async(dispatch_get_main_queue(), ^{ // 要在主线程中执行
            [_jsBridge[@"callbackAsyn"] callWithArguments:callBackParams];
        });
    }
}

// 回调，传 String 给js。
- (void)callBackSuccess:(BOOL)success withString:(NSString *)string toInvocation:(MXMethodInvocation *)invocation {
    UIWebView *webview = _webview;
    if (webview && invocation.invocationID) {
        // 只要检测webview是否还在，就可以了
        // 回调JS。
        NSNumber *status = success ? MXBridge_ReturnCode_OK : MXBridge_ReturnCode_FAILED;
        NSArray *callBackParams = string ? @[invocation.invocationID,status,string] : @[invocation.invocationID,status];
        dispatch_async(dispatch_get_main_queue(), ^{
            [_jsBridge[@"callbackAsyn"] callWithArguments:callBackParams];
        });
    }
}


@end