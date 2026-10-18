#import "JFV2EventSender.h"
#import "JFPlaybackTrace.h"
#import "JFV2ControlCodec.h"
#import <dispatch/dispatch.h>
#import <Security/Security.h>
#import "API/JFWorker.h"
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>
#include <stdlib.h>
// User-configurable Mac audio Bridge endpoint. No developer home LAN address
// or any pairing secret is included in the public build. This plist contains
// ONLY the address (e.g. http://192.168.1.10:8899), never a credential.
static NSString *JFV2BridgeURL(void) {
    NSDictionary *prefs=[NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/org.jellyfin.atv3.bridge.plist"];
    NSString *raw=prefs[@"AudioBridgeURL"];
    if(![raw isKindOfClass:[NSString class]] || raw.length<10 || raw.length>180)
        return @"http://127.0.0.1:8899";
    NSURLComponents *parsed=[NSURLComponents componentsWithString:raw];
    if(!parsed || ![@[@"http",@"https"] containsObject:parsed.scheme] ||
       !parsed.host.length || parsed.user || parsed.password || parsed.query ||
       parsed.fragment || parsed.path.length>1 || !parsed.port ||
       parsed.port.integerValue<=0 || parsed.port.integerValue>65535)
        return @"http://127.0.0.1:8899";
    return [raw hasSuffix:@"/"]?[raw substringToIndex:raw.length-1]:raw;
}
@interface JFV2BoundedHTTP : NSObject <NSURLConnectionDataDelegate> {
    NSMutableData *_data; BOOL _done; BOOL _failed; NSInteger _status;
}
+ (NSDictionary *)request:(NSURLRequest *)request;
@end
@implementation JFV2BoundedHTTP
+ (NSDictionary *)request:(NSURLRequest *)request {
    JFV2BoundedHTTP *d=[[[self alloc] init] autorelease];d->_data=[NSMutableData new];
    NSURLConnection *connection=[[[NSURLConnection alloc] initWithRequest:request delegate:d startImmediately:YES] autorelease];
    NSTimeInterval deadline=[NSProcessInfo processInfo].systemUptime+1.5;
    while (!d->_done && [NSProcessInfo processInfo].systemUptime<deadline)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    [connection cancel];
    if (!d->_done || d->_failed || d->_status!=200) return nil;
    id result=[NSJSONSerialization JSONObjectWithData:d->_data options:0 error:NULL];
    return [result isKindOfClass:[NSDictionary class]]?result:nil;
}
- (NSURLRequest *)connection:(NSURLConnection *)c willSendRequest:(NSURLRequest *)r redirectResponse:(NSURLResponse *)response {
    if (response) {_failed=YES;_done=YES;return nil;}return r;
}
- (void)connection:(NSURLConnection *)c didReceiveResponse:(NSURLResponse *)response {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {_failed=YES;_done=YES;[c cancel];return;}
    _status=[(NSHTTPURLResponse *)response statusCode];
}
- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)data {
    if (_data.length+data.length>4096) {_failed=YES;_done=YES;[c cancel];return;}[_data appendData:data];
}
- (void)connectionDidFinishLoading:(NSURLConnection *)c {_done=YES;}
- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)error {_failed=YES;_done=YES;}
- (void)dealloc {[_data release];[super dealloc];}
@end
static NSString *RandomID(void) {
    unsigned char b[16];if (SecRandomCopyBytes(kSecRandomDefault,sizeof(b),b)!=errSecSuccess)return nil;
    NSMutableString *s=[NSMutableString string];for (int i=0;i<16;i++)[s appendFormat:@"%02x",b[i]];return s;
}
static BOOL HexID(id s) {
    return [s isKindOfClass:[NSString class]] && [s length]==32 && [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
@interface JFV2EventSender () {
    NSData *_key; dispatch_queue_t _queue; dispatch_semaphore_t _pending;
    NSString *_session,*_epoch; long long _sequence,_serverMS; NSTimeInterval _helloMono;
    BOOL _invalid; BOOL _syncPending; void (^_termination)(BOOL); void (^_started)(void); void (^_committed)(void); BOOL _confirmedStopped; BOOL _startPrepared;
    long long _clockOffsetUS, _clockUncertaintyUS; BOOL _clockReady; NSUInteger _clockProbeCount;
}
@end
@implementation JFV2EventSender
@synthesize termination=_termination,started=_started,committed=_committed;
- (id)initWithKey:(NSData *)key {
    if ((self=[super init])) {
        if (key.length!=32) {[self release];return nil;}
        _key=[key copy];_queue=dispatch_queue_create("org.atv3.v2.control",DISPATCH_QUEUE_SERIAL);
        _pending=dispatch_semaphore_create(4);
    }return self;
}
- (BOOL)hello {
    NSString *nonce=RandomID();if (!nonce)return NO;
    NSURL *url=[NSURL URLWithString:[[JFV2BridgeURL() stringByAppendingString:@"/v2/hello?nonce="] stringByAppendingString:nonce]];
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.5];
    NSTimeInterval t0=[NSProcessInfo processInfo].systemUptime;
    NSDictionary *reply=[JFV2BoundedHTTP request:r];
    NSTimeInterval t2=[NSProcessInfo processInfo].systemUptime;
    JFPlaybackTrace(reply ? @"V2_HELLO_HTTP_200_JSON" : @"V2_HELLO_HTTP_OR_JSON_FAILED");
    NSString *epoch=reply[@"epoch"];
    if (!HexID(epoch) || !JFV2Receipt(_key,reply,epoch,nonce) || [reply[@"v"] intValue]!=2 ||
        ![reply[@"ts_ms"] isKindOfClass:[NSNumber class]] || [reply[@"logical_only"] boolValue] || ![reply[@"handoff"] isEqual:@"prepare-commit-1"]) {
        JFPlaybackTrace(@"V2_HELLO_RECEIPT_REJECTED");return NO;}
    [_epoch release];_epoch=[epoch copy];_serverMS=[reply[@"ts_ms"] longLongValue];
    _helloMono=t2;
    _clockReady=NO;
    // The signed hello includes the Mac's monotonic receive timestamp.
    // One-way transport is uncertain by half the measured RTT; reject >40ms.
    NSNumber *macMonoUS=reply[@"mac_mono_us"];
    double rtt=t2-t0;
    _clockProbeCount=0;
    JFPlaybackTrace([NSString stringWithFormat:@"V2_CLOCK_HELLO_RTT rtt_ms=%ld clock_field=%d",
      (long)(rtt*1000.0),(int)[macMonoUS isKindOfClass:[NSNumber class]]]);
    if ([macMonoUS isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((CFTypeRef)macMonoUS)!=CFBooleanGetTypeID() &&
        rtt>=0 && rtt<=0.080 && isfinite(rtt)) {
        long long macUS=[macMonoUS longLongValue];
        if (macUS>0) {
            _clockOffsetUS=macUS-llround((t0+t2)*500000.0);
            _clockUncertaintyUS=llround(rtt*500000.0);
            _clockReady=llabs(_clockOffsetUS)<=3000000000000000LL &&
                        _clockUncertaintyUS>=0 && _clockUncertaintyUS<=40000;
        }
    }
    JFPlaybackTrace([NSString stringWithFormat:@"V2_CLOCK_SAMPLE valid=%d uncertainty_ms=%ld",
       (int)_clockReady,(long)(_clockUncertaintyUS/1000)]);
    JFPlaybackTrace(@"V2_HELLO_VERIFIED");return YES;
}
- (void)event:(NSString *)kind plan:(NSDictionary *)plan ticks:(long long)ticks {
    if (![@[@"start",@"commit",@"pause",@"resume",@"seek",@"sync",@"stop"] containsObject:kind] || ticks<0 || ticks>9007199254740991LL)return;
    BOOL isSync=[kind isEqual:@"sync"];
    @synchronized(self) {
        if (_invalid)return;
        // One sync at a time. Newer native progress supersedes a queued
        // heartbeat, freeing this serial queue for pause/seek/resume.
        if (isSync) {
            if (_syncPending) {JFPlaybackTrace(@"V2_SYNC_COALESCED");return;}
            _syncPending=YES;
        }
    }
    if (dispatch_semaphore_wait(_pending,DISPATCH_TIME_NOW)!=0) {
        if (isSync) @synchronized(self) {_syncPending=NO;}
        // Dropped periodic heartbeat is harmless: the next fresh sync (or
        // explicit pause/seek/stop) will follow. Do not terminate a signed
        // audio session just because the main thread briefly fell behind.
        if ([kind isEqual:@"sync"]) {
            JFPlaybackTrace(@"V2_SYNC_QUEUE_FULL_DROPPED");
            return;
        }
        JFPlaybackTrace(@"V2_CONTROL_QUEUE_FULL_INVALIDATE");
        [self invalidate];return;
    }
    // Snapshot time immediately after the current main-thread LTAVPlayer read.
    NSTimeInterval created=[NSProcessInfo processInfo].systemUptime;
    long long sampleUS=llround(created*1000000.0);
    NSDictionary *metadata=[plan copy];NSString *command=[kind copy];
    dispatch_async(_queue,^{ @autoreleasepool {
        BOOL valid=NO;@synchronized(self){valid=!_invalid;}
        BOOL recoverableSyncTransportFailure=NO;
        // Preserve the established <1-second freshness gate, but distinguish
        // a disposable periodic sync from a command whose delivery matters.
        // A stale sync has NOT been assigned a sequence number, and must
        // NEVER kill the authenticated session or silence a playing video.
        if (valid && [command isEqual:@"sync"] &&
            [NSProcessInfo processInfo].systemUptime-created>=1.0) {
            JFPlaybackTrace(@"V2_SYNC_QUEUE_EXPIRED_DROPPED");
            @synchronized(self){_syncPending=NO;}
            [metadata release];[command release];
            dispatch_semaphore_signal(_pending);
            return;
        }
        // A native pause needs to be honored even when the previous sync
        // consumed the 1.5-second HTTP bound. Mac authenticates the new
        // timestamp *at send*, not at queue creation. No stale position is
        // used for a pause, and the session remains fail-closed on rejection.
        NSTimeInterval queueAge=[NSProcessInfo processInfo].systemUptime-created;
        NSTimeInterval freshness=[command isEqual:@"pause"]?2.5:1.0;
        if (valid && queueAge<freshness) {
            if ([command isEqual:@"start"]) JFPlaybackTrace(@"V2_SENDER_START_ENTER");
            if ([command isEqual:@"start"]) {
                // Reuse the authenticated session while Mac asynchronously
                // prepares a missing cache; never retry after prepare/commit.
                if (_startPrepared || !HexID(metadata[@"itemID"]) || !HexID(metadata[@"sourceID"]) ||
                    ![metadata[@"audioStreamIndex"] isKindOfClass:[NSNumber class]]) valid=NO;
                else if (!_session) {
                    if (![self hello]) valid=NO;
                    else {_session=[RandomID() copy];_sequence=0;JFPlaybackTrace(@"V2_SENDER_SESSION_CREATED");}
                }
                if (!valid) JFPlaybackTrace(@"V2_SENDER_START_REJECTED");
            }
            if (!_session || !_epoch)valid=NO;
            if (valid) {
                NSMutableDictionary *event=[NSMutableDictionary dictionaryWithDictionary:@{@"type":command,@"session":_session,@"seq":@(++_sequence)}];
                if ([command isEqual:@"start"]) {
                    event[@"item"]=metadata[@"itemID"];event[@"source"]=metadata[@"sourceID"];event[@"track"]=metadata[@"audioStreamIndex"];
                }
                if ([@[@"start",@"commit",@"seek",@"sync"] containsObject:command]) event[@"seconds"]=@((double)ticks/10000000.0);
                if ([command isEqual:@"commit"]) event[@"paused"]=@([metadata[@"paused"] boolValue]);
                if ([command isEqual:@"sync"] && _clockReady) {
                    event[@"sample_us"]=@(sampleUS);
                    event[@"offset_us"]=@(_clockOffsetUS);
                    event[@"uncertainty_us"]=@(_clockUncertaintyUS);
                }
                NSString *nonce=RandomID();
                long long stamp=_serverMS+(long long)(([NSProcessInfo processInfo].systemUptime-_helloMono)*1000);
                NSData *body=JFV2Envelope(_key,_epoch,event,stamp,nonce);
                NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[JFV2BridgeURL() stringByAppendingString:@"/v2/control"]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.5];
                r.HTTPMethod=@"POST";r.HTTPBody=body;[r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                @synchronized(self){if (_invalid)body=nil;}
                NSTimeInterval commandSent=[NSProcessInfo processInfo].systemUptime;
                NSDictionary *reply=body?[JFV2BoundedHTTP request:r]:nil;
                // No answer to a periodic sync is not an authenticated
                // rejection. The Mac's native 5-second watchdog independently
                // stops orphaned sound; a later signed heartbeat can recover.
                recoverableSyncTransportFailure=([command isEqual:@"sync"] &&
                    body && reply==nil);
                NSTimeInterval commandReceived=[NSProcessInfo processInfo].systemUptime;
                if ([command isEqual:@"start"]) JFPlaybackTrace(reply ? @"V2_START_HTTP_200_JSON" : @"V2_START_HTTP_OR_JSON_FAILED");
                NSString *expected=@{@"start":@"prepare",@"commit":@"commit",@"pause":@"pause",@"resume":@"resume",@"seek":@"seek",@"sync":@"observe",@"stop":@"stop"}[command];
                BOOL signatureOK=JFV2Receipt(_key,reply,_epoch,nonce);
                if ([command isEqual:@"start"]) {
                    JFPlaybackTrace(signatureOK ? @"V2_START_RECEIPT_SIGNATURE_OK" : @"V2_START_RECEIPT_SIGNATURE_FAILED");
                    if (reply && ![reply[@"ok"] boolValue]) JFPlaybackTrace(@"V2_START_REPLY_NOT_OK");
                    if (reply && [reply[@"ok"] boolValue] && ![reply[@"kind"] isEqual:expected]) {
                        NSString *responseKind=reply[@"kind"];
                        if ([responseKind isKindOfClass:[NSString class]] &&
                            [@[@"cache-miss",@"ignored",@"prepare",@"stop",@"none",@"pause",@"observe",@"commit"] containsObject:responseKind])
                            JFPlaybackTrace([NSString stringWithFormat:@"V2_START_RESPONSE_KIND %@",responseKind]);
                        else JFPlaybackTrace(@"V2_START_RESPONSE_KIND unknown");
                        JFPlaybackTrace([NSString stringWithFormat:@"V2_START_AUDIO_TRACK %ld",(long)[metadata[@"audioStreamIndex"] integerValue]]);
                        JFPlaybackTrace(@"V2_START_REPLY_KIND_MISMATCH");
                    }
                }
                BOOL cachePending=[command isEqual:@"start"] && signatureOK &&
                    [reply[@"ok"] boolValue] && [reply[@"kind"] isEqual:@"cache-miss"];
                valid=(signatureOK && [reply[@"ok"] boolValue] && [reply[@"kind"] isEqual:expected]) || cachePending;
                if ([command isEqual:@"start"] && valid && !cachePending) {
                    @synchronized(self) {_startPrepared=YES;}
                }
                // Signed, monotonic Mac clock is piggybacked on every valid
                // control receipt. If hello's one-shot RTT failed, recover
                // automatically during the same playback without extra requests.
                if (valid && [@[@"start",@"commit",@"sync"] containsObject:command]) {
                    NSNumber *stamp=reply[@"mac_mono_us"];
                    double rtt=commandReceived-commandSent;
                    if (!_clockReady && _clockProbeCount++<5)
                        JFPlaybackTrace([NSString stringWithFormat:
                            @"V2_CLOCK_REPLY_RTT kind=%@ rtt_ms=%ld clock_field=%d",
                            command,(long)(rtt*1000.0),
                            (int)[stamp isKindOfClass:[NSNumber class]]]);
                    if ([stamp isKindOfClass:[NSNumber class]] &&
                        CFGetTypeID((CFTypeRef)stamp)!=CFBooleanGetTypeID() &&
                        isfinite(rtt) && rtt>=0 && rtt<=0.080) {
                        long long remoteUS=[stamp longLongValue];
                        long long offset=remoteUS-llround((commandSent+commandReceived)*500000.0);
                        long long uncertainty=llround(rtt*500000.0);
                        if (remoteUS>0 && llabs(offset)<=3000000000000000LL &&
                            uncertainty>=0 && uncertainty<=40000 &&
                            (!_clockReady || uncertainty<_clockUncertaintyUS)) {
                            BOOL recovered=!_clockReady;
                            _clockOffsetUS=offset;
                            _clockUncertaintyUS=uncertainty;
                            _clockReady=YES;
                            if (recovered) JFPlaybackTrace([NSString stringWithFormat:
                                @"V2_CLOCK_RECOVERED uncertainty_ms=%ld",
                                (long)(uncertainty/1000)]);
                        }
                    }
                }
                if (valid && [command isEqual:@"sync"]) {
                    NSDictionary *observation=reply[@"observation"];
                    NSString *state=observation[@"auto_sync_state"];
                    if ([@[@"seek",@"would-seek",@"hold",@"aligned",@"observe",@"no-timestamp"] containsObject:state]) {
                        long phase=[observation[@"auto_sync_phase_ms"] longValue];
                        long step=[observation[@"auto_sync_step_ms"] longValue];
                        JFPlaybackTrace([NSString stringWithFormat:@"V2_AUTO_SYNC state=%@ phase_ms=%ld step_ms=%ld",state,phase,step]);
                    }
                }
                // The signed prepare receipt confirms silence, not playback.
                // On rejected start/offline Mac, native HDMI audio stays intact.
                if ([command isEqual:@"start"] && valid && !cachePending) {
                    dispatch_async(dispatch_get_main_queue(),^{
                        BOOL active=NO;@synchronized(self){active=!_invalid;}
                        void (^callback)(void)=[self.started copy];
                        if (active && callback)callback();[callback release];
                    });
                }
                if ([command isEqual:@"commit"] && valid) {
                    dispatch_async(dispatch_get_main_queue(),^{
                        BOOL active=NO;@synchronized(self){active=!_invalid;}
                        void (^callback)(void)=[self.committed copy];
                        if (active && callback)callback();
                        [callback release];
                    });
                }
                if ([command isEqual:@"stop"] && valid) _confirmedStopped=YES;
                if ([command isEqual:@"stop"]) valid=NO; // New sender/session needed for next movie.
            }
        } else {valid=NO;if ([command isEqual:@"start"]) JFPlaybackTrace(@"V2_START_QUEUE_EXPIRED_OR_INVALID");}
        if ([command isEqual:@"commit"] || [command isEqual:@"sync"] ||
            [command isEqual:@"stop"] || [command isEqual:@"pause"] ||
            [command isEqual:@"resume"]) {
            JFPlaybackTrace([NSString stringWithFormat:@"V2_CONTROL_RESULT kind=%@ seq=%lld valid=%d",command,_sequence,(int)valid]);
        }
        if (!valid) {
            BOOL nonfatal=NO;
            @synchronized(self) {
                nonfatal=recoverableSyncTransportFailure && !_invalid;
            }
            if (nonfatal) {
                JFPlaybackTrace(@"V2_SYNC_TRANSPORT_FAILURE_NONFATAL");
            } else {
                JFPlaybackTrace([NSString stringWithFormat:@"V2_CONTROL_INVALIDATE kind=%@",command]);
                [self invalidate];
            }
        } // No retries, and no autonomous restart after an actual rejection.
        if ([command isEqual:@"sync"]) @synchronized(self){_syncPending=NO;}
        [metadata release];[command release];dispatch_semaphore_signal(_pending);
    }});
}
- (BOOL)preparedAccepted {
    @synchronized(self) {return _startPrepared;}
}
- (void)invalidate {
    @synchronized(self){if (_invalid)return;_invalid=YES;}
    JFPlaybackTrace(@"V2_SENDER_INVALIDATED");
    // Serialize cleanup after any in-flight request. No queued command can
    // revive this sender; only this authenticated stop is allowed after invalidation.
    dispatch_async(_queue,^{ @autoreleasepool {
        if (!_confirmedStopped && _session && _epoch) {
            NSString *nonce=RandomID();
            long long stamp=_serverMS+(long long)(([NSProcessInfo processInfo].systemUptime-_helloMono)*1000);
            NSDictionary *event=@{@"type":@"stop",@"session":_session,@"seq":@(++_sequence)};
            NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[JFV2BridgeURL() stringByAppendingString:@"/v2/control"]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.5];
            r.HTTPMethod=@"POST";r.HTTPBody=JFV2Envelope(_key,_epoch,event,stamp,nonce);
            NSDictionary *reply=[JFV2BoundedHTTP request:r];
            _confirmedStopped=JFV2Receipt(_key,reply,_epoch,nonce) && [reply[@"ok"] boolValue] && [reply[@"kind"] isEqual:@"stop"];
        }
        BOOL stopped=_confirmedStopped;
        dispatch_async(dispatch_get_main_queue(),^{
            void (^callback)(BOOL)=[self.termination copy];
            if (callback)callback(stopped);[callback release];
        });
    }});
}
- (void)dealloc {[_committed release];[_started release];[_termination release];[_key release];[_session release];[_epoch release];dispatch_release(_pending);dispatch_release(_queue);[super dealloc];}
@end


// Pre-playback barrier: called ONLY on JFWorker's background thread.
// Never start or present native video until the Mac has signed a verified
// complete AAC cache for the exact Jellyfin source and audio stream.
BOOL JFV2WaitForAudioCache(NSString *item, NSString *source, NSInteger track) {
#if defined(JF_AUDIO_GATE_HOST_FIXTURE)
    // Host-only test fixture: the playback JSON uses symbolic movie1/source1.
    // The signed LAN warm barrier must remain mandatory in every ARMv7 build.
    JFPlaybackTrace([NSString stringWithFormat:@"HOST_AUDIO_GATE_FIXTURE item=%@ source=%@ track=%ld",
                     item ?: @"nil",source ?: @"nil",(long)track]);
    if (![NSThread isMainThread] && !JFWorkCancelled() &&
        [item isEqualToString:@"movie1"] && [source isEqualToString:@"source1"] &&
        track==1) return YES;
#endif
    if ([NSThread isMainThread] || !HexID(item) || !HexID(source) ||
        track<0 || track>10000 || JFWorkCancelled()) return NO;
    NSString *configPath=@"/var/mobile/Library/Preferences/org.atv3.jellyfin-audio-v2.plist";
    struct stat st;
    if (lstat(configPath.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode) ||
        (st.st_mode&077) || st.st_nlink!=1 ||
        (st.st_uid!=getuid() && st.st_uid!=0)) return NO;
    NSDictionary *config=[NSDictionary dictionaryWithContentsOfFile:configPath];
    NSData *key=config[@"PairKey"];
    if (![config[@"Enabled"] boolValue] || [config[@"Version"] intValue]!=2 ||
        ![key isKindOfClass:[NSData class]] || key.length!=32) return NO;
    NSString *helloNonce=RandomID();if (!helloNonce)return NO;
    NSURL *helloURL=[NSURL URLWithString:[[JFV2BridgeURL() stringByAppendingString:@"/v2/hello?nonce="] stringByAppendingString:helloNonce]];
    NSMutableURLRequest *helloReq=[NSMutableURLRequest requestWithURL:helloURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.5];
    NSDictionary *hello=[JFV2BoundedHTTP request:helloReq];
    NSString *epoch=hello[@"epoch"];
    if (!HexID(epoch) || !JFV2Receipt(key,hello,epoch,helloNonce) ||
        [hello[@"v"] intValue]!=2 || [hello[@"logical_only"] boolValue] ||
        ![hello[@"handoff"] isEqual:@"prepare-commit-1"] ||
        ![hello[@"ts_ms"] isKindOfClass:[NSNumber class]]) {
        JFPlaybackTrace(@"AUDIO_CACHE_GATE_HELLO_FAILED"); return NO;
    }
    long long serverMS=[hello[@"ts_ms"] longLongValue];
    NSTimeInterval helloMono=[NSProcessInfo processInfo].systemUptime;
    NSTimeInterval deadline=helloMono+600.0;
    NSString *session=RandomID();
    if (!session) return NO;
    long long sequence=0;
    BOOL pendingLogged=NO;
    while (!JFWorkCancelled() && [NSProcessInfo processInfo].systemUptime<deadline) {
        @autoreleasepool {
            NSString *nonce=RandomID(); if (!nonce)return NO;
            NSDictionary *event=@{@"type":@"warm",@"session":session,
                                  @"seq":@(++sequence),@"item":item,
                                  @"source":source,@"track":@(track)};
            long long timestamp=serverMS+(long long)(([NSProcessInfo processInfo].systemUptime-helloMono)*1000.0);
            NSData *body=JFV2Envelope(key,epoch,event,timestamp,nonce);
            if (!body) return NO;
            NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[JFV2BridgeURL() stringByAppendingString:@"/v2/control"]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.5];
            r.HTTPMethod=@"POST";r.HTTPBody=body;
            [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            NSDictionary *reply=[JFV2BoundedHTTP request:r];
            if (!JFV2Receipt(key,reply,epoch,nonce) || ![reply[@"ok"] boolValue]) {
                JFPlaybackTrace(@"AUDIO_CACHE_GATE_VERIFICATION_FAILED");
                return NO; // fail closed: NEVER start silent video
            }
            NSString *kind=reply[@"kind"];
            if ([kind isEqual:@"ready"]) {
                JFPlaybackTrace(@"AUDIO_CACHE_GATE_READY");
                return !JFWorkCancelled();
            }
            if (![kind isEqual:@"cache-miss"]) {
                JFPlaybackTrace(@"AUDIO_CACHE_GATE_INVALID_STATE");return NO;
            }
            if (!pendingLogged) {JFPlaybackTrace(@"AUDIO_CACHE_GATE_WAIT_NAS");pendingLogged=YES;}
        }
        // Cancellation must remain responsive when the user presses Menu.
        [NSThread sleepForTimeInterval:1.0];
    }
    JFPlaybackTrace(JFWorkCancelled()?@"AUDIO_CACHE_GATE_CANCELLED":@"AUDIO_CACHE_GATE_TIMED_OUT");
    return NO;
}
